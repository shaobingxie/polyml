(*
    Copyright (c) 2013-2015 David C.J. Matthews

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License version 2.1 as published by the Free Software Foundation.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

(* Signature for debugging flags *)
signature DEBUGSIG =
sig
    val assemblyCodeTag : bool Universal.tag
    val bindingCounterTag : (unit -> int) Universal.tag
    val codetreeAfterOptTag : bool Universal.tag
    val codetreeTag : bool Universal.tag
    val createPrintFunctionsTag : bool Universal.tag
    val debugTag : bool Universal.tag
    val defaults : Universal.universal list
    val errorDepthTag : int Universal.tag
    val fileNameTag : string Universal.tag
    val getParameter : 'a Universal.tag -> Universal.universal list -> 'a
    val inlineFunctorsTag : bool Universal.tag
    val lineLengthTag : int Universal.tag
    val lineNumberTag : (unit -> int) Universal.tag
    val lowlevelOptimiseTag : bool Universal.tag
    val maxInlineSizeTag : int Universal.tag
    val narrowOverloadFlexRecordTag : bool Universal.tag
    val offsetTag : (unit -> int) Universal.tag
    val parsetreeTag : bool Universal.tag
    val printDepthFunTag : (unit -> int) Universal.tag
    val profileAllocationTag : int Universal.tag
    val pstackTraceTag : bool Universal.tag
    val reportExhaustiveHandlersTag : bool Universal.tag
    val reportUnreferencedIdsTag : bool Universal.tag
    val traceCompilerTag : bool Universal.tag
    val reportDiscardedValuesTag: int Universal.tag
    val reportDiscardNone: int (* No reports *)
    and reportDiscardFunction: int (* Only report discarded functions *)
    and reportDiscardNonUnit: int (* Report discarding any non unit values *)
end;
