--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Cases is

   procedure Level (N : Natural) is
   begin
      Depth_Reached := N;
      if N = 0 then
         raise Custom with "from the bottom";
      end if;
      Level (N - 1);
      Depth_Reached := 1_000;   --  must not run
   end Level;

   procedure Reset_Log is
   begin
      Log_Len := 0;
      Log := [others => '-'];
   end Reset_Log;

   procedure Note (C : Character) is
   begin
      Log_Len := Log_Len + 1;
      Log (Log_Len) := C;
   end Note;

   overriding procedure Finalize (G : in out Guard) is
   begin
      Note (G.Id);
   end Finalize;

   procedure Guarded (Fail : Boolean) is
      A : Guard (Id => 'a');
      pragma Unreferenced (A);
   begin
      declare
         B : Guard (Id => 'b');
         pragma Unreferenced (B);
      begin
         declare
            C : Guard (Id => 'c');
            pragma Unreferenced (C);
         begin
            if Fail then
               raise Other with "inside the guards";
            end if;
         end;
         Note ('x');   --  only without the failure
      end;
      Note ('y');
   end Guarded;

   function Divide (A, B : Integer) return Integer is
   begin
      return A / B;
   end Divide;

   function Make_Small (V : Integer) return Small is
   begin
      return V;
   end Make_Small;

   function Contains (Text : String; Part : String) return Boolean is
   begin
      if Part'Length = 0 then
         return True;
      end if;
      for I in Text'First .. Text'Last - Part'Length + 1 loop
         if Text (I .. I + Part'Length - 1) = Part then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

end Cases;
