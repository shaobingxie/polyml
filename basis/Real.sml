(*
    Title:      Standard Basis Library: Real Signature and structure.
    Author:     David Matthews
    Copyright   David Matthews 2000, 2005, 2008, 2016

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

structure Real: REAL =
struct
    open RuntimeCalls IEEEReal
    
    (* This is used for newly added functions in the Standard Basis. *)
    (* We want to get the io function once for each function, not once
       per call, but that's complicated in ML97. *)
    local
        val doReal : int*real->real =
            RunCall.run_call2 POLY_SYS_Real_Dispatch
    in
        fun callReal n x = doReal(n, x)
    end

    local
        val doReal : int*(real*real)->real =
            RunCall.run_call2 POLY_SYS_Real_Dispatch
    in
        fun callRealReal n p = doReal(n, p)
    end

    local
        val doReal : int*real->bool =
            RunCall.run_call2 POLY_SYS_Real_Dispatch
    in
        fun callRealToBool n x = doReal(n, x)
    end

    local
        val doReal : int*real->int =
            RunCall.run_call2 POLY_SYS_Real_Dispatch
    in
        fun callRealToInt n x = doReal(n, x)
    end
        
    type real = real (* Pick up from globals. *)

    structure Math: MATH =
    struct
        type real = real (* Pick up from globals. *)
        
        (* These are provided directly in the RTS.  *)
        (* These are the old functions which had separate entries in the
           interface vector.  *)
        val sqrt:   real -> real = RunCall.run_call1 POLY_SYS_sqrt_real;
        val sin:    real -> real = RunCall.run_call1 POLY_SYS_sin_real;
        val cos:    real -> real = RunCall.run_call1 POLY_SYS_cos_real;
        val atan:   real -> real = RunCall.run_call1 POLY_SYS_arctan_real;
        val exp:    real -> real = RunCall.run_call1 POLY_SYS_exp_real;
        val ln:     real -> real = RunCall.run_call1 POLY_SYS_ln_real;
    
        (* Functions added for ML 97.  These use the Real_dispatch entry. *)
         (* It may well be possible to derive these from the old ML90 functions
           but it's almost certainly quicker to implement them in the RTS. *)
        val tan = callReal 0
        val asin = callReal 1
        val acos = callReal 2
        val atan2 = callRealReal 3
        val pow = callRealReal 4
        val log10 = callReal 5
        val sinh = callReal 6
        val cosh = callReal 7
        val tanh = callReal 8
        
        (* Derived values. *)
        val e = exp 1.0
        val pi = 4.0 * atan 1.0
    
    end;


    infix 4 == != ?=;

    val op == : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_eq;
    val op != : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_neq;

    val radix : int = callRealToInt 11 0.0
    val precision : int = callRealToInt 12 0.0
    val maxFinite : real = callReal 13 0.0
    val minNormalPos : real = callReal 14 0.0

    val posInf : real = 1.0/0.0;
    val negInf : real = ~1.0/0.0;
    
    (* We only implement this sort of real. *)
    fun toLarge (x: real) : (*LargeReal.*)real =x
    fun fromLarge (_ : IEEEReal.rounding_mode) (x: (*LargeReal.*)real): real = x

    (* NAN values fail any test including equality with themselves. *)
    fun isNan x = x != x
    (* NAN values do not match and infinities when multiplied by 0 produce NAN. *)
    fun isFinite x = x * 0.0 == 0.0
    
    val signBit : real -> bool = callRealToBool 17
    val copySign : (real * real) -> real = callRealReal 18

    (* If we assume that all functions produce normalised results where
       possible, the only subnormal values will be those smaller than
       minNormalPos. *)
    fun isNormal x = isFinite x andalso abs x >= minNormalPos
    
    fun class x =
        if isFinite x then if x == 0.0 then ZERO
           else if abs x >= minNormalPos then NORMAL
           else SUBNORMAL
        else if isNan x then NAN
           else (* not finite and not Nan *) INF
    
    fun sign x = 
        if isNan x then raise General.Domain
        else if x == 0.0 then 0 else if x < 0.0 then ~1 else 1
        
    fun sameSign (x, y) = signBit x = signBit y
    
    fun unordered (x, y) = isNan x orelse isNan y

    (* Returns the minimum.  In the case where one is a NaN it returns the
       other. In that case the comparison will be false. *)
    fun min (a: real, b: real): real = if a < b orelse isNan b then a else b
    (* Similarly for max. *)
    fun max (a: real, b: real): real = if a > b orelse isNan b then a else b

    fun checkFloat x =
        if isFinite x then x
        else if isNan x then raise General.Div else raise General.Overflow

    val fromLargeInt: LargeInt.int -> real = RunCall.run_call1 POLY_SYS_int_to_real
    val fromInt: int  -> real = RunCall.run_call1 POLY_SYS_fixed_to_real

    val radixAsReal (* Not exported *) = fromInt radix
    val epsilon (* Not exported *) = Math.pow(radixAsReal, fromInt (Int.-(1, precision)))

    val minPos : real = minNormalPos*epsilon;

    local
        val toMantissa : real->real = callReal 24
        and toExponent : real->int = callRealToInt 25

        val doReal : int*(real*int)->real =
            RunCall.run_call2 POLY_SYS_Real_Dispatch

        fun fromManAndExp (ri: real*int): real = doReal(23, ri)
    in
        fun toManExp r = 
            if not (isFinite r) orelse r == 0.0
            (* Nan, infinities and +/-0 all return r in the mantissa.
               We include 0 to preserve its sign. *)
            then {man=r, exp=0}
            else {man=toMantissa r, exp=toExponent r}

        fun fromManExp {man, exp} = 
            if not (isFinite man) orelse man == 0.0
            (* Nan, infinities and +/-0 in the mantissa all return
               their argument. *)
            then man
            else fromManAndExp(man, exp)
    end

    (* Convert to integer.  Ideally this would do the rounding/truncation as part of the
       conversion but it doesn't seem to be possible to detect overflow properly.
       Instead we use the real rounding/truncation, convert to arbitrary
       precision and then check for overflow if necessary.  *)
    local
        (* The RTS function converts to at most a 64-bit value (even on 
           32-bits).  That will convert all the bits of the mantissa
           but if the exponent is large we may have to multiply by
           some power of two. *)
        val realToInt: real -> LargeInt.int  = RunCall.run_call1 POLY_SYS_real_to_int
    in
        
        val realFloor = callReal 19
        and realCeil  = callReal 20
        and realTrunc = callReal 21
        and realRound = callReal 22

        fun toArbitrary x = 
            if isNan x then raise General.Domain
            else if not (isFinite x) then raise General.Overflow
            else
            let
                val { man, exp } = toManExp x
            in
                if exp <= precision
                then realToInt x
                else IntInf.<< (realToInt(fromManExp{man=man, exp=precision}), Word.fromInt(exp - precision))
            end

        fun floor x = toArbitrary(realFloor x)
        (* Returns the largest integer <= x. *)

        fun ceil x = toArbitrary(realCeil x)
        (* Returns the smallest integer >= x. *)

        fun trunc x = toArbitrary(realTrunc x)
        (* Truncate towards zero. *)

        fun round x = toArbitrary(realRound x)
        (* Return the nearest integer, returning an even value if equidistant. *)
        
        fun toLargeInt IEEEReal.TO_NEGINF r = floor r
         |  toLargeInt IEEEReal.TO_POSINF r = ceil r
         |  toLargeInt IEEEReal.TO_ZERO r = trunc r
         |  toLargeInt IEEEReal.TO_NEAREST r = round r

        fun toInt mode x = LargeInt.toInt(toLargeInt mode x)
        
        val floor = LargeInt.toInt o floor
        and ceil  = LargeInt.toInt o ceil
        and trunc = LargeInt.toInt o trunc
        and round = LargeInt.toInt o round
    end;

    local
        val realConv: string->real = RunCall.run_call1 POLY_SYS_conv_real

        val posNan = abs(0.0 / 0.0)
        val negNan = ~posNan
    in
        fun fromDecimal { class = INF, sign=true, ...} = SOME negInf
          | fromDecimal { class = INF, sign=false, ...} = SOME posInf
          | fromDecimal { class = ZERO, sign=true, ...} = SOME ~0.0
          | fromDecimal { class = ZERO, sign=false, ...} = SOME 0.0
             (* Generate signed Nans ignoring the digits and mantissa.  There
                was code here to set the mantissa but there's no reference to
                that in the current version of the Basis library.  *)
          | fromDecimal { class = NAN, sign=true, ... } = SOME negNan
          | fromDecimal { class = NAN, sign=false, ... } = SOME posNan

          | fromDecimal { class = _ (* NORMAL or SUBNORMAL *), sign, digits, exp} =
            (let
                fun toChar x =
                    if x < 0 orelse x > 9 then raise General.Domain
                    else Char.chr (x + Char.ord #"0")
                (* Turn the number into a string. *)
                val str = "0." ^ String.implode(List.map toChar digits) ^"E" ^
                    Int.toString exp
                (* Convert it to a real using the RTS conversion function.
                   Change any Conversion exceptions into Domain. *)
                val result = realConv str handle RunCall.Conversion _ => raise General.Domain
            in
                if sign then SOME (~result) else SOME result
            end 
                handle General.Domain => NONE
            )
    end
        
    local
        val dtoa: real*int*int -> string*int*int = RunCall.run_call3 POLY_SYS_Real_str
        open StringCvt

        fun addZeros n =
            if n <= 0 then "" else "0" ^ addZeros (n-1)

        fun fixFmt ndigs r =
        if isNan r then "nan"
        else if not (isFinite r)
        then if r < 0.0 then "~inf" else "inf"
        else
        let
            (* Try to get ndigs past the decimal point. *)
            val (str, exp, sign) = dtoa(r, 3, ndigs)
            val strLen = String.size str
            (* If the exponents is negative or zero we need to put a zero
               before the decimal point.  If the exponent is positive and
               less than the number of digits we can take that
               many characters off, otherwise we have to pad with zeros. *)
            val numb =
                if exp <= 0
                then (* Exponent is zero or negative - all significant digits are
                        after the decimal point.  Put in any zeros before
                        the significant digits, then the significant digits
                        and then any trailing zeros. *)
                    if ndigs = 0 then "0"
                    else "0." ^ addZeros(~exp) ^ str ^ addZeros(ndigs-strLen+exp)
                else if strLen <= exp
                then (* Exponent is not less than the length of the string -
                        all significant digits are before the decimal point. Add
                        any extra zeros before the decimal point then zeros after it. *)
                    str ^ addZeros(exp-strLen) ^ 
                        (if ndigs = 0 then "" else "." ^ addZeros ndigs)
                else (* Significant digits straddle the decimal point - insert the
                        decimal point and add any trailing zeros. *)
                    String.substring(str, 0, exp) ^ "." ^
                        String.substring(str, exp, strLen-exp) ^ 
                            addZeros(ndigs-strLen+exp)
        in
            if sign <> 0 then "~" ^ numb else numb
        end
        
        fun sciFmt ndigs r =
        if isNan r then "nan"
        else if not (isFinite r)
        then if r < 0.0 then "~inf" else "inf"
        else
        let
            (* Try to get ndigs+1 digits.  1 before the decimal point and ndigs after. *)
            val (str, exp, sign) = dtoa(r, 2, ndigs+1)
            val strLen = String.size str
            fun addZeros n =
                if n <= 0 then "" else "0" ^ addZeros (n-1)
            val numb =
                if strLen = 0
                then "0" ^ (if ndigs = 0 then "" else "." ^ addZeros ndigs) ^ "E0"
                else 
                   (if strLen = 1
                    then str ^ (if ndigs = 0 then "" else "." ^ addZeros ndigs)
                    else String.substring(str, 0, 1) ^ "." ^
                            String.substring(str, 1, strLen-1) ^ addZeros (ndigs-strLen+1)
                    ) ^ "E" ^ Int.toString (exp-1)
        in
            if sign <> 0 then "~" ^ numb else numb
        end

        fun genFmt ndigs r =
        if isNan r then "nan"
        else if not (isFinite r)
        then if r < 0.0 then "~inf" else "inf"
        else
        let
            (* Try to get ndigs digits. *)
            val (str, exp, sign) = dtoa(r, 2, ndigs)
            val strLen = String.size str
            val numb =
            (* Have to use scientific notation if exp > ndigs.  Also use it
               if the exponent is small (TODO: adjust this) *)
                if exp > ndigs orelse exp < ~5
                then (* Scientific format *)
                   (if strLen = 1 then str
                    else String.substring(str, 0, 1) ^ "." ^
                            String.substring(str, 1, strLen-1)
                    ) ^ "E" ^ Int.toString (exp-1)

                else (* Fixed format (N.B. no trailing zeros are added after the
                        decimal point apart from one if necessary) *)
                    if exp <= 0
                then (* Exponent is zero or negative - all significant digits are
                        after the decimal point.  Put in any zeros before
                        the significant digits, then the significant digits
                        and then any trailing zeros. *)
                    "0." ^ addZeros(~exp) ^ str
                else if strLen <= exp
                then (* Exponent is not less than the length of the string -
                        all significant digits are before the decimal point. Add
                        any extra zeros before the decimal point. Insert .0 at the
                        end to make it a valid real number. *)
                    str ^ addZeros(exp-strLen) ^ ".0"
                else (* Significant digits straddle the decimal point - insert the
                        decimal point. *)
                    String.substring(str, 0, exp) ^ "." ^
                        String.substring(str, exp, strLen-exp)
        in
            if sign <> 0 then "~" ^ numb else numb
        end

        fun strToDigitList str =
        let
            fun getDigs i l =
                if i < 0 then l
                else getDigs (i-1)
                        ((Char.ord(String.sub(str, i)) - Char.ord #"0") :: l)
        in
            getDigs (String.size str - 1) []
        end
    in
        fun toDecimal r =
        let
            val sign = signBit r
            val kind = class r
        in
            case kind of
                ZERO => { class = ZERO, sign = sign, digits=[], exp = 0 }
              | INF  => { class = INF, sign = sign, digits=[], exp = 0 }
              | NAN => { class = NAN, sign = sign, digits=[], exp = 0 }
              | _ => (* NORMAL/SUBNORMAL *)
                let
                    val (str, exp, sign) = dtoa(r, 0, 0)
                    val digits = strToDigitList str
                in
                    { class = kind, sign = sign <> 0, digits = digits, exp = exp }
                end
        end

        (* Note: The definition says, reasonably, that negative values
           for the number of digits raises Size.  The tests also check
           for a very large value for the number of digits and seem to
           expect Size to be raised in that case.  Note that the exception
           is raised when fmt spec is evaluated and before it is applied
           to an actual real argument.
           In all cases, even EXACT format, this should produce "nan" for a NaN
           and ignore the sign bit. *)
        fun fmt (SCI NONE) = sciFmt 6
          | fmt (SCI (SOME d) ) =
                if d < 0 orelse d > 200 then raise General.Size
                else sciFmt d
          | fmt (FIX NONE) = fixFmt 6
          | fmt (FIX (SOME d) ) =
                if d < 0 orelse d > 200 then raise General.Size
                else fixFmt d
          | fmt (GEN NONE) = genFmt 12
          | fmt (GEN (SOME d) ) =
                if d < 1 orelse d > 200 then raise General.Size
                else genFmt d
          | fmt EXACT = (fn r => if isNan r then "nan" else IEEEReal.toString(toDecimal r))
          
        val toString = fmt (GEN NONE)
    end


    fun scan getc src =
    let
        (* Return a list of digits. *)
        fun getdigits inp src =
            case getc src of
                NONE => (List.rev inp, src)
              | SOME(ch, src') =>
                    if ch >= #"0" andalso ch <= #"9"
                    then getdigits ((Char.ord ch - Char.ord #"0") :: inp) src'
                    else (List.rev inp, src)

        (* Read an unsigned integer.  Returns NONE if no digits have been read. *)
        fun getNumber sign digits acc src =
            case getc src of
                NONE => if digits = 0 then NONE else SOME(if sign then ~acc else acc, src)
              | SOME(ch, src') =>
                    if ch >= #"0" andalso ch <= #"9"
                    then getNumber sign (digits+1) (acc*10 + Char.ord ch - Char.ord #"0") src'
                    else if digits = 0 then NONE else SOME(if sign then ~acc else acc, src')

        (* Return the signed exponent. *)
        fun getExponent src =
            case getc src of
                NONE => NONE
              | SOME(ch, src') =>
                if ch = #"+"
                then getNumber false 0 0 src'
                else if ch = #"-" orelse ch = #"~"
                then getNumber true 0 0 src'
                else getNumber false 0 0 src

        fun read_number sign src =
            case getc src of
                NONE => NONE
              | SOME(ch, _) =>
                    if not (ch >= #"0" andalso ch <= #"9" orelse ch = #".")
                    then NONE (* Bad *)
                    else (* Digits or decimal. *)
                    let
                        (* Get the digits before the decimal point (if any) *)
                        val (intPart, srcAfterDigs) = getdigits [] src
                        (* Get the digits after the decimal point (if any).
                           If there is a decimal point we only accept it if
                           there is at least one digit after it. *)
                        val (decimals, srcAfterMant) =
                            case getc srcAfterDigs of
                                NONE => ([], srcAfterDigs)
                             |  SOME (#".", srcAfterDP) =>
                                    ( (* Check that the next character is a digit. *)
                                    case getc srcAfterDP of
                                        NONE => ([], srcAfterDigs)
                                      | SOME(ch, _) =>
                                            if ch >= #"0" andalso ch <= #"9"
                                            then getdigits [] srcAfterDP
                                            else ([], srcAfterDigs)
                                    )
                             |  SOME (_, _) => ([], srcAfterDigs)
                        (* The exponent is optional.  If it doesn't form a valid
                           exponent we return zero as the value and the
                           continuation is the beginning of the "exponent". *)
                        val (exponent, srcAfterExp) =
                            case getc srcAfterMant of
                                NONE => (0, srcAfterMant)
                             |  SOME (ch, src'''') =>
                                if ch = #"e" orelse ch = #"E"
                                then 
                                    (
                                    case getExponent src'''' of
                                        NONE => (0, srcAfterMant)
                                      | SOME x => x 
                                    )
                                else (0, srcAfterMant)
                        (* Generate a decimal representation ready for conversion.
                           We don't bother to strip off leading or trailing zeros. *)
                        val decimalRep = {class=NORMAL, sign=sign,
                                digits=List.@(intPart, decimals),
                                exp=exponent + List.length intPart}
                    in
                        case fromDecimal decimalRep of
                           SOME r => SOME(r, srcAfterExp)
                         | NONE => NONE
                    end
    in
        case getc src of
            NONE => NONE
         |  SOME(ch, src') =>
            if Char.isSpace ch (* Skip white space. *)
            then scan getc src' (* Recurse *)
            else if ch = #"+" (* Remove the + sign *)
            then read_number false src'
            else if ch = #"-" orelse ch = #"~"
            then read_number true src'
            else (* See if it's a valid digit. *)
                read_number false src
    end
    
    val fromString = StringCvt.scanString scan

    (* Converter to real values. This replaces the basic conversion
       function for reals installed in the bootstrap process.
       For more information see convInt in Int. *)
    (* Don't use it for the moment because it doesn't really provide any
       advantage over the existing function. *)
    (*
    local
        structure Conversion =
          RunCall.Run_exception1
            (
              type ex_type = string;
              val ex_iden  = EXC_conversion
            );
        exception Conversion = Conversion.ex;
        fun convReal s =
            case StringCvt.scanString scan s of
                NONE => raise Conversion "Invalid real constant"
              | SOME res => res
    in
        (* Install this as a conversion function for real literals. *)
        val (): unit = RunCall.addOverload convReal "convReal"
    end
    *)

    val op + : (real * real) -> real = RunCall.run_call2 POLY_SYS_Add_real;
    val op - : (real * real) -> real = RunCall.run_call2 POLY_SYS_Sub_real;
    val op * : (real * real) -> real = RunCall.run_call2 POLY_SYS_Mul_real;
    val op / : (real * real) -> real = RunCall.run_call2 POLY_SYS_Div_real;

    val op < : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_lss;
    val op <= : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_leq;
    val op > : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_gtr;
    val op >= : (real * real) -> bool = RunCall.run_call2 POLY_SYS_Real_geq;

    fun compare (r1, r2) =
        if r1 == r2 then General.EQUAL
        else if r1 < r2 then General.LESS
        else if r1 > r2 then General.GREATER
        else raise Unordered

    fun compareReal (r1, r2) =
        if r1 == r2 then EQUAL
        else if r1 < r2 then LESS
        else if r1 > r2 then GREATER
        else UNORDERED

    (* Question: The definition says "bitwise equal, ignoring signs on zeros".
       If we assume that all numbers are normalised, is that the same as "equal"?*)
    fun op ?= (x, y) =
        isNan x orelse isNan y orelse x == y

    (* Although these may be built in in some architectures it's
       probably not worth treating them specially at the moment. *)
    fun *+ (x: real, y: real, z: real): real = x*y+z
    and *- (x: real, y: real, z: real): real = x*y-z

    val ~ : real -> real = RunCall.run_call1 POLY_SYS_Neg_real
    (* This was previously done by a test and negation but it's difficult
       to get that right for +/- NaN *)
    and abs : real -> real = RunCall.run_call1 POLY_SYS_Abs_real
    
    fun rem (x, y) =
        if not (isFinite y) andalso not (isNan y) then x
        else x - realTrunc(x / y)*y

    (* Split a real into whole and fractional parts. The fractional part must have
       the same sign as the number even if it is zero. *)
    fun split r =
    let
        val whole = realTrunc r
        val frac = r - whole
    in
        { whole = whole,
          frac =
            if not (isFinite r)
            then if isNan r then r else (* Infinity *) if r < 0.0 then ~0.0 else 0.0
            else if frac == 0.0 then if signBit r then ~0.0 else 0.0
            else frac }
    end

    (* Get the fractional part of a real. *)
    fun realMod r = #frac(split r)

    local
        (* For normalised numbers the next in the sequence is x*(1+epsilon).
           However for unnormalised values we may have to multiply the epsilon
           value by the radix. *)

        fun nextUp r p =
        let
            val nxt = r + r*p
        in
            if nxt == r then nextUp r (p*radixAsReal)
            else nxt
        end

        fun nextDown r p =
        let
            val prev = r - r*p
        in
            if prev == r then nextDown r (p*radixAsReal)
            else prev
        end
    in
        fun nextAfter (r, t) =
            if not (isFinite r) orelse r == t then r
            else if r < t then nextUp r epsilon else nextDown r epsilon
    end

end;

structure Math = Real.Math;

structure LargeReal: REAL = Real;

(* Values available unqualified at the top-level. *)
val real : int -> real = Real.fromInt 
val trunc : real -> int = Real.trunc 
val floor : real -> int = Real.floor 
val ceil : real -> int = Real.ceil 
val round : real -> int =Real.round;

(* Install print function. *)
local
    fun print_real _ _ (r: real) =
        PolyML.PrettyString(Real.fmt (StringCvt.GEN(SOME 10)) r)
in
    val () = PolyML.addPrettyPrinter print_real;
end;
