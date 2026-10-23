--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  exceptions_test: zero-cost exceptions (R8) of the embedded runtime of
--  crates/mpfs_rts. An exception is propagated by the unwinder of libgcc,
--  which finds the frame descriptions (FDEs) of the .eh_frame section through
--  the registration that start.S triggers (no .eh_frame_hdr, see
--  crates/mpfs_rts/README.md).
--
--    - raise and handle, in the same frame and through several calls;
--    - the message, the name and Exception_Information of an occurrence;
--    - reraise (raise;) and Reraise_Occurrence keep the occurrence;
--    - the checks of the language (Constraint_Error, Program_Error);
--    - finalization of controlled objects while an exception propagates, in
--      the reverse order of their creation;
--    - an exception raised in a handler replaces the one being handled;
--    - an exception propagates in a task and is handled there.
--
--  Reported with Test_Report as exceptions_test_e51 or exceptions_test_u54.
--  unhandled_test (the same project) covers what happens to an exception that
--  nobody handles.

with Ada.Exceptions; use Ada.Exceptions;
with Ada.Real_Time;  use Ada.Real_Time;
with Interfaces;     use type Interfaces.Unsigned_64;

with Bare_Console;
with Cases;          use Cases;
with Test_Report;
with Worker;

procedure Exceptions_Test is

   procedure Start;

   procedure Start is
   begin
      case Bare_Console.Hart_Id is
         when 0      => Test_Report.Start ("exceptions_test_e51");
         when others => Test_Report.Start ("exceptions_test_u54");
      end case;
   end Start;

   --  The log of the two constructors of ctor.S.
   Ctor_Log : String (1 .. 8)
     with Import, Volatile, External_Name => "exceptions_test_ctor_log";
   Ctor_Len : Interfaces.Unsigned_64
     with Import, Volatile, External_Name => "exceptions_test_ctor_len";

   Caught : Boolean;
   Step   : Natural;
   Value  : Integer;

begin
   Start;

   --  0. The constructor arrays were run before the main program: preinit
   --  first, then init (where crtbegin's frame_dummy registered .eh_frame).
   Test_Report.Check
     (Ctor_Len = 2 and then Ctor_Log (1 .. 2) = "pi",
      "the constructor arrays ran in order before main");

   --  1. Raise and handle in one frame.
   Caught := False;
   begin
      raise Custom;
   exception
      when Custom => Caught := True;
   end;
   Test_Report.Check (Caught, "raise and handle in one frame");

   --  2. Through five frames; the code after the call does not run.
   Caught := False;
   begin
      Level (4);
   exception
      when E : Custom =>
         Caught := Exception_Message (E) = "from the bottom"
           and then Exception_Identity (E) = Custom'Identity;
   end;
   Test_Report.Check (Caught, "an exception propagates through 5 frames");
   Test_Report.Check (Depth_Reached = 0,
                      "the code after the raising call did not run");

   --  3. Name, message and information of the occurrence.
   begin
      raise Other with "the message";
   exception
      when E : others =>
         Test_Report.Check
           (Exception_Name (E) = "CASES.OTHER",
            "Exception_Name is the full name");
         Test_Report.Check
           (Exception_Message (E) = "the message", "Exception_Message");
         Test_Report.Check
           (Contains (Exception_Information (E),
                      "raised CASES.OTHER : the message"),
            "Exception_Information has the name and the message");
   end;

   --  4. Reraise: the outer handler sees the same occurrence.
   Caught := False;
   Step := 0;
   begin
      begin
         raise Custom with "reraised";
      exception
         when Custom =>
            Step := 1;
            raise;
      end;
   exception
      when E : Custom =>
         Caught := Step = 1 and then Exception_Message (E) = "reraised";
   end;
   Test_Report.Check (Caught, "raise; propagates the same occurrence");

   --  5. Reraise_Occurrence of a saved occurrence, after the handler is left.
   declare
      Saved : Exception_Occurrence;
   begin
      Caught := False;
      begin
         raise Other with "saved";
      exception
         when E : others =>
            Save_Occurrence (Saved, E);
      end;
      begin
         Reraise_Occurrence (Saved);
      exception
         when E : Other =>
            Caught := Exception_Message (E) = "saved";
      end;
   end;
   Test_Report.Check (Caught, "Reraise_Occurrence of a saved occurrence");

   --  6. Checks of the language.
   Caught := False;
   begin
      Value := Divide (10, Zero);
      Test_Report.Info ("unexpected quotient", Bare_Console.U64 (Value));
   exception
      when Constraint_Error => Caught := True;
   end;
   Test_Report.Check (Caught, "division by zero raises Constraint_Error");

   Caught := False;
   begin
      Value := Make_Small (11 + Zero);
      Test_Report.Info ("unexpected value", Bare_Console.U64 (Value));
   exception
      when Constraint_Error => Caught := True;
   end;
   Test_Report.Check (Caught, "a range check raises Constraint_Error");

   Caught := False;
   begin
      raise Program_Error with "explicit";
   exception
      when E : Program_Error =>
         Caught := Exception_Message (E) = "explicit";
   end;
   Test_Report.Check (Caught, "Program_Error with a message");

   --  7. Finalization while an exception propagates.
   Reset_Log;
   Caught := False;
   begin
      Guarded (Fail => True);
   exception
      when E : Other =>
         Caught := Exception_Message (E) = "inside the guards";
   end;
   Test_Report.Check
     (Caught and then Log (1 .. Log_Len) = "cba",
      "controlled objects are finalized in reverse order during propagation");

   Reset_Log;
   Guarded (Fail => False);
   Test_Report.Check
     (Log (1 .. Log_Len) = "cxbya",
      "without an exception the same code finalizes normally");

   --  8. A handler that raises another exception replaces the first.
   Caught := False;
   begin
      begin
         raise Custom with "first";
      exception
         when others =>
            raise Other with "second";
      end;
   exception
      when E : Other => Caught := Exception_Message (E) = "second";
   end;
   Test_Report.Check (Caught, "an exception raised in a handler propagates");

   --  9. A task propagates an exception into its own handler.
   for I in 1 .. 100 loop
      exit when Worker.Done;
      delay until Clock + Milliseconds (10);
   end loop;
   Test_Report.Check
     (Worker.Done and Worker.Caught, "an exception is handled in a task");

   Test_Report.Finish;
end Exceptions_Test;
