--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);
--  The light-tasking profile has no exception propagation, so a check that
--  could fail would be a warning (an error here); the code is exact without

with Bare_Console;
with Istack;
with Test_Name;
with Test_Report;

package body Istack_Check is

   Current : Test := Peak_Of_Trap;
   Main_Count, Fault_Count : Interfaces.Unsigned_64 := 0;
   --  Instructions retired from reset to the main program, and at the trap

   -----------
   -- Start --
   -----------

   procedure Start (Which : Test; At_Main : Interfaces.Unsigned_64 := 0) is
   begin
      Current := Which;
      Main_Count := At_Main;
      Istack.Paint;
      Fault_Count := Istack.Instret;
   end Start;

   ---------------
   -- Ends_With --
   ---------------

   function Ends_With (Text, Tail : String) return Boolean is
     (Text'Length >= Tail'Length
      and then Text (Text'Last - Tail'Length + 1 .. Text'Last) = Tail);
   --  The light-tasking profile prefixes the message of a raise with the
   --  place of the raise ("System.BB.Interrupts.Stack_Overflow: ...")

   -----------------
   -- Last_Chance --
   -----------------

   procedure Last_Chance (Message : String) is
      use type Bare_Console.U64;
      use type Interfaces.Unsigned_64;

      Trap_Count : constant Interfaces.Unsigned_64 :=
                     Istack.Instret - Fault_Count;
      --  First thing: the instructions from the trap to here

      Size : constant Bare_Console.U64 := Bare_Console.U64 (Istack.Size);
      --  Modular arithmetic for the comparison: no overflow check, which
      --  the light-tasking profile could not raise
   begin
      case Current is
         when Peak_Of_Trap =>
            Test_Report.Check
              (Message = "Unhandled trap: 2",
               "the trap ends as Program_Error with the message of the cause");
            Test_Report.Info ("interrupt stack, bytes", Size);
            Test_Report.Info
              ("instructions, reset to the main program",
               Bare_Console.U64 (Main_Count));
            Test_Report.Info
              ("instructions, trap to the last chance handler",
               Bare_Console.U64 (Trap_Count));

            declare
               --  After the report above: what it used is part of the peak
               Peak : constant Bare_Console.U64 :=
                        Bare_Console.U64 (Istack.Peak);
            begin
               Test_Report.Info ("interrupt stack, peak in bytes", Peak);
               Test_Report.Check
                 (Peak > 0 and then Peak * 3 <= Size * 2,
                  "the peak is at most two thirds of the stack "
                  & "(a margin of 50 %)");
               Test_Report.Check
                 (Peak <= Test_Name.Peak_Limit,
                  "the peak is below the limit of the profile (embedded: the "
                  & "frame descriptions were sorted before main)");
            end;

         when Overrun_In_Handler =>
            Test_Report.Check
              (Istack.Overran,
               "the handler used a frame that reaches below the stack");
            Test_Report.Check
              (Ends_With (Message, "interrupt stack overflow"),
               "the program ends with the message "
               & """interrupt stack overflow""");
      end case;
      Test_Report.Finish;
   end Last_Chance;

end Istack_Check;
