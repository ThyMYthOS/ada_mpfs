--  SPDX-FileCopyrightText: 1992-2020 Free Software Foundation, Inc.
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes gnat_rts_sources
--  rts-sources/common/s-textio.ads @ 09e7cd6; the interface is unchanged. Only
--  the pragma of the unit differs: Restrictions (No_Elaboration_Code) instead
--  of No_Elaboration_Code_All. The body uses the register package of the PAC,
--  which has the restriction but not the stronger pragma (every unit that the
--  body names would need it).
--
--  This package defines the console I/O interface for the simplified version
--  of Ada.Text_IO used in embedded systems with limited I/O capabilities.

pragma Restrictions (No_Elaboration_Code);

package System.Text_IO is
   pragma Preelaborate;

   --  The interface uses two subprograms for each direction: one for the ready
   --  status and one for the action. This is done on purpose to avoid busy
   --  waiting loops in the body.

   procedure Initialize;
   --  Must be called before all other subprograms to initialize the service.
   --  We avoid the use of elaboration to make this package preelaborated.

   Initialized : Boolean := False;
   --  Set to True (by Initialize) when the service is initialized. Having this
   --  variable outside allows reinitialization of the service.

   --------------
   --  Output  --
   --------------

   function Is_Tx_Ready return Boolean;
   --  Return True if it is possible to call Put. This function can be used for
   --  checking that the output register of an UART is empty before write a
   --  new character on it. For non blocking output system, this function can
   --  always return True. Once this function has returned True, it must always
   --  return True before the next call to Put.

   procedure Put (C : Character);
   --  Write a character on the console. Must be called only when Is_Tx_Ready
   --  has returned True before, otherwise its behavior is undefined.

   function Use_Cr_Lf_For_New_Line return Boolean;
   --  Return True if New_Line should output CR + LF, otherwise it will output
   --  only LF.

   -------------
   --  Input  --
   -------------

   function Is_Rx_Ready return Boolean;
   --  Return True is a character can be read by Get. On systems where is it
   --  difficult or impossible to know wether a character is available, this
   --  function can always return True and Get will be blocking.

   function Get return Character;
   --  Read a character from the console. Must be called only when Is_Rx_Ready
   --  has returned True, otherwise behavior is undefined.
end System.Text_IO;
