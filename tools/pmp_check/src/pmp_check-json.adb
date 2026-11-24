--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A reader of the JSON of the check input: a recursive descent over the source, each step with the
--  position of the next character as its state.

package body Pmp_Check.Json
  with SPARK_Mode
is
   use type Interfaces.Unsigned_64;

   function Valid_Source (Src : String) return Boolean is
     (Src'First = 1 and then Src'Last in 0 .. Max_Source);

   --  Where the reader is: <Pos> the next character (Src'Last + 1 at the end); not <Ok> after a failure at
   --  <Err_Pos>.
   type State is record
      Pos     : Positive := 1;
      Ok      : Boolean := True;
      Err_Pos : Natural := 0;
   end record;

   function In_Source (Src : String; St : State) return Boolean is (St.Pos <= Src'Last + 1)
     with Pre => Valid_Source (Src);

   procedure Fail (St : in out State)
     with Post => St.Pos = St.Pos'Old and then not St.Ok
   is
   begin
      if St.Ok then
         St.Ok := False;
         St.Err_Pos := St.Pos;
      end if;
   end Fail;

   procedure Skip_Space (Src : String; St : in out State)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St),
          Post => In_Source (Src, St) and then St.Ok = St.Ok'Old
   is
   begin
      while St.Pos <= Src'Last and then Src (St.Pos) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
         pragma Loop_Invariant (St.Pos <= Src'Last and then St.Ok = St.Ok'Loop_Entry);
         St.Pos := St.Pos + 1;
      end loop;
   end Skip_Space;

   --  A new node of kind <K>; 0 if the document is full (and the parse failed).
   procedure New_Node (Doc : in out Document; St : in out State; K : Kind; Id : out Node_Id)
     with Post => St.Pos = St.Pos'Old
   is
   begin
      if Doc.Used = Max_Nodes then
         Fail (St);
         Id := 0;
      else
         Doc.Used := Doc.Used + 1;
         Id := Doc.Used;
         Doc.Nodes (Id) := (K => K, others => <>);
      end if;
   end New_Node;

   --  <Child> as the last child of <Parent>, after <Last> (0: the first).
   procedure Link (Doc : in out Document; Parent, Child : Valid_Node; Last : Node_Id) is
   begin
      if Last = 0 then
         Doc.Nodes (Parent).Child := Child;
      else
         Doc.Nodes (Last).Next := Child;
      end if;
   end Link;

   --  A string at Pos (on its opening quote): its first and last character.
   procedure Read_String (Src : String; St : in out State; First : out Positive; Last : out Natural)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St),
          Post => In_Source (Src, St)
   is
   begin
      First := 1;
      Last := 0;
      if St.Pos > Src'Last or else Src (St.Pos) /= '"' then
         Fail (St);
         return;
      end if;
      St.Pos := St.Pos + 1;
      First := St.Pos;
      while St.Pos <= Src'Last and then Src (St.Pos) /= '"' loop
         pragma Loop_Invariant (St.Pos <= Src'Last);
         if Src (St.Pos) = '\' or else Src (St.Pos) < ' ' then
            Fail (St);
            return;
         end if;
         St.Pos := St.Pos + 1;
      end loop;
      if St.Pos > Src'Last then
         Fail (St);
         return;
      end if;
      Last := St.Pos - 1;
      St.Pos := St.Pos + 1;
   end Read_String;

   procedure Read_Number (Src : String; St : in out State; Value : out U64)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St),
          Post => In_Source (Src, St)
   is
      Digit : U64;
   begin
      Value := 0;
      if St.Pos > Src'Last or else Src (St.Pos) not in '0' .. '9' then
         Fail (St);
         return;
      end if;
      if Src (St.Pos) = '0' and then St.Pos < Src'Last and then Src (St.Pos + 1) in '0' .. '9' then
         Fail (St);    --  a leading zero
         return;
      end if;
      while St.Pos <= Src'Last and then Src (St.Pos) in '0' .. '9' loop
         pragma Loop_Invariant (St.Pos <= Src'Last);
         Digit := Character'Pos (Src (St.Pos)) - Character'Pos ('0');
         if Value > (U64'Last - Digit) / 10 then
            Fail (St);
            return;
         end if;
         Value := Value * 10 + Digit;
         St.Pos := St.Pos + 1;
      end loop;
      if St.Pos <= Src'Last and then Src (St.Pos) in '.' | 'e' | 'E' then
         Fail (St);
      end if;
   end Read_Number;

   procedure Read_Word (Src : String; St : in out State; Word : String)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St),
          Post => In_Source (Src, St)
   is
   begin
      for C of Word loop
         pragma Loop_Invariant (In_Source (Src, St));
         if St.Pos > Src'Last or else Src (St.Pos) /= C then
            Fail (St);
            return;
         end if;
         St.Pos := St.Pos + 1;
      end loop;
   end Read_Word;

   procedure Value (Src : String; St : in out State; Doc : in out Document; Depth : Natural; Id : out Node_Id)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St),
          Post => In_Source (Src, St);

   procedure Array_Value (Src : String; St : in out State; Doc : in out Document; Depth : Natural;
                          Id : Valid_Node)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St) and then St.Pos <= Src'Last
                  and then Depth <= Max_Depth,
          Post => In_Source (Src, St)
   is
      Last  : Node_Id := 0;
      Child : Node_Id;
   begin
      St.Pos := St.Pos + 1;    --  [
      Skip_Space (Src, St);
      if St.Pos <= Src'Last and then Src (St.Pos) = ']' then
         St.Pos := St.Pos + 1;
         return;
      end if;
      loop
         pragma Loop_Invariant (In_Source (Src, St));
         Value (Src, St, Doc, Depth + 1, Child);
         exit when not St.Ok or else Child = 0;
         Link (Doc, Id, Child, Last);
         Last := Child;
         Skip_Space (Src, St);
         if St.Pos <= Src'Last and then Src (St.Pos) = ',' then
            St.Pos := St.Pos + 1;
         elsif St.Pos <= Src'Last and then Src (St.Pos) = ']' then
            St.Pos := St.Pos + 1;
            return;
         else
            Fail (St);
            return;
         end if;
      end loop;
   end Array_Value;

   procedure Object_Value (Src : String; St : in out State; Doc : in out Document; Depth : Natural;
                           Id : Valid_Node)
     with Pre  => Valid_Source (Src) and then In_Source (Src, St) and then St.Pos <= Src'Last
                  and then Depth <= Max_Depth,
          Post => In_Source (Src, St)
   is
      Last      : Node_Id := 0;
      Child     : Node_Id;
      Key_First : Positive;
      Key_Last  : Natural;
   begin
      St.Pos := St.Pos + 1;    --  {
      Skip_Space (Src, St);
      if St.Pos <= Src'Last and then Src (St.Pos) = '}' then
         St.Pos := St.Pos + 1;
         return;
      end if;
      loop
         pragma Loop_Invariant (In_Source (Src, St));
         Skip_Space (Src, St);
         Read_String (Src, St, Key_First, Key_Last);
         exit when not St.Ok;
         Skip_Space (Src, St);
         if St.Pos > Src'Last or else Src (St.Pos) /= ':' then
            Fail (St);
            return;
         end if;
         St.Pos := St.Pos + 1;
         Value (Src, St, Doc, Depth + 1, Child);
         exit when not St.Ok or else Child = 0;
         Doc.Nodes (Child).Key_First := Key_First;
         Doc.Nodes (Child).Key_Last := Key_Last;
         Link (Doc, Id, Child, Last);
         Last := Child;
         Skip_Space (Src, St);
         if St.Pos <= Src'Last and then Src (St.Pos) = ',' then
            St.Pos := St.Pos + 1;
         elsif St.Pos <= Src'Last and then Src (St.Pos) = '}' then
            St.Pos := St.Pos + 1;
            return;
         else
            Fail (St);
            return;
         end if;
      end loop;
   end Object_Value;

   procedure Value (Src : String; St : in out State; Doc : in out Document; Depth : Natural; Id : out Node_Id)
   is
   begin
      Id := 0;
      Skip_Space (Src, St);
      if not St.Ok or else Depth > Max_Depth or else St.Pos > Src'Last then
         Fail (St);
         return;
      end if;
      case Src (St.Pos) is
         when '{' =>
            New_Node (Doc, St, J_Object, Id);
            if Id /= 0 then
               Object_Value (Src, St, Doc, Depth, Id);
            end if;
         when '[' =>
            New_Node (Doc, St, J_Array, Id);
            if Id /= 0 then
               Array_Value (Src, St, Doc, Depth, Id);
            end if;
         when '"' =>
            New_Node (Doc, St, J_String, Id);
            if Id /= 0 then
               declare
                  First : Positive;
                  Last  : Natural;
               begin
                  Read_String (Src, St, First, Last);
                  Doc.Nodes (Id).S_First := First;
                  Doc.Nodes (Id).S_Last := Last;
               end;
            end if;
         when '0' .. '9' =>
            New_Node (Doc, St, J_Number, Id);
            if Id /= 0 then
               declare
                  V : U64;
               begin
                  Read_Number (Src, St, V);
                  Doc.Nodes (Id).Num := V;
               end;
            end if;
         when 't' =>
            New_Node (Doc, St, J_True, Id);
            Read_Word (Src, St, "true");
         when 'f' =>
            New_Node (Doc, St, J_False, Id);
            Read_Word (Src, St, "false");
         when 'n' =>
            New_Node (Doc, St, J_Null, Id);
            Read_Word (Src, St, "null");
         when others =>
            Fail (St);
      end case;
   end Value;

   procedure Parse (Src : String; Doc : out Document; Root : out Node_Id; Ok : out Boolean;
                    Err_Pos : out Natural)
   is
      St : State;
   begin
      Doc := (Nodes => [others => (others => <>)], Used => 0);
      Value (Src, St, Doc, 0, Root);
      if St.Ok then
         Skip_Space (Src, St);
         if St.Pos <= Src'Last then
            Fail (St);
         end if;
      end if;
      Ok := St.Ok;
      Err_Pos := St.Err_Pos;
      if not Ok then
         Root := 0;
      end if;
   end Parse;

   function Member (Doc : Document; Src : String; Obj : Node_Id; Key : String) return Node_Id is
      Cur : Node_Id;
   begin
      if Obj = 0 or else Doc.Nodes (Obj).K /= J_Object then
         return 0;
      end if;
      Cur := Doc.Nodes (Obj).Child;
      for Step in 1 .. Max_Nodes loop
         exit when Cur = 0;
         if Slice (Src, Doc.Nodes (Cur).Key_First, Doc.Nodes (Cur).Key_Last) = Key then
            return Cur;
         end if;
         Cur := Doc.Nodes (Cur).Next;
      end loop;
      return 0;
   end Member;

end Pmp_Check.Json;
