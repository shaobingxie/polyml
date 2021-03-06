(*
    Copyright (c) 2006, 2015 David C. J. Matthews

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

structure X86OutputCode =
    X86OUTPUTCODE(
        structure DEBUG   = Debug
        structure PRETTY  = Pretty
    );

structure X86Optimise =
    X86OPTIMISE(
        structure X86CODE = X86OutputCode
    );

structure CodeCons =
    X86FIRST_STAGE(
        structure X86CODE = X86OutputCode
        structure X86OPTIMISE = X86Optimise
	    structure DEBUG    = Debug
	    structure MISC     = Misc
	    structure PRETTY   = Pretty
    );
