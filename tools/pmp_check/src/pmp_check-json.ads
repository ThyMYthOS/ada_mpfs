--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A reader of the JSON that the generator writes as the check input: objects, arrays, strings
--  without escapes, non-negative integers up to 2 ** 64 - 1, true, false and null. Anything else (an
--  escape, a sign, a fraction, an exponent, a document nested deeper than Max_Depth or with more
--  than Max_Nodes values) is refused. The values are nodes of a Document; a string is a slice of the
--  source, and so is the key of an object member.

package Pmp_Check.Json
  with SPARK_Mode
is
   Max_Nodes  : constant := 32_768;
   Max_Depth  : constant := 16;
   Max_Source : constant := 2 ** 26;      --  64 MiB

   type Node_Id is range 0 .. Max_Nodes;   --  0: none
   subtype Valid_Node is Node_Id range 1 .. Max_Nodes;

   type Kind is (J_Null, J_False, J_True, J_Number, J_String, J_Array, J_Object);

   type Node is record
      K         : Kind := J_Null;
      Num       : U64 := 0;                --  J_Number
      S_First   : Positive := 1;           --  J_String: the source slice S_First .. S_Last
      S_Last    : Natural := 0;
      Key_First : Positive := 1;           --  a member of an object: its key
      Key_Last  : Natural := 0;
      Child     : Node_Id := 0;            --  the first element or member
      Next      : Node_Id := 0;            --  the next element or member of the parent
   end record;

   type Node_Array is array (Valid_Node) of Node;

   type Document is record
      Nodes : Node_Array;
      Used  : Node_Id := 0;
   end record;

   --  <Src> parsed into <Doc>; <Root> its value. Not <Ok>: <Err_Pos> is where it failed.
   procedure Parse (Src : String; Doc : out Document; Root : out Node_Id; Ok : out Boolean;
                    Err_Pos : out Natural)
     with Pre => Src'First = 1 and then Src'Last in 0 .. Max_Source;

   --  The slice <First> .. <Last> of <Src> (empty if it is not inside <Src>).
   function Slice (Src : String; First : Positive; Last : Natural) return String is
     (if First <= Last and then First >= Src'First and then Last <= Src'Last then Src (First .. Last)
      else "");

   function Kind_Of (Doc : Document; N : Node_Id) return Kind is
     (if N = 0 then J_Null else Doc.Nodes (N).K);

   --  The member <Key> of the object <Obj>; 0 if <Obj> is no object or has no such member.
   function Member (Doc : Document; Src : String; Obj : Node_Id; Key : String) return Node_Id;

   --  The first element or member of <N>, and the one after <N>; 0: none.
   function First_Child (Doc : Document; N : Node_Id) return Node_Id is
     (if N = 0 then 0 else Doc.Nodes (N).Child);
   function Next_Sibling (Doc : Document; N : Node_Id) return Node_Id is
     (if N = 0 then 0 else Doc.Nodes (N).Next);

   --  The string of a J_String node (empty for another node).
   function Text_Of (Doc : Document; Src : String; N : Node_Id) return String is
     (if N /= 0 and then Doc.Nodes (N).K = J_String
      then Slice (Src, Doc.Nodes (N).S_First, Doc.Nodes (N).S_Last) else "");

end Pmp_Check.Json;
