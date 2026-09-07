using System.Globalization;

namespace Emerald.Runtime;

/// <summary>
/// Emerald's arithmetic and number formatting, with no compiler in sight.
///
/// This is the first slice of the shipped runtime library. It exists because the
/// interpreter was the only copy of these rules, and a backend built against that would
/// have reimplemented them: two implementations of rounding, of float printing, of the
/// division that floors -- diffed against each other by nobody. The conformance cases in
/// tests/cases stop being a comparison between two implementations and become a test of
/// the only one.
///
/// Nothing here takes an interpreter, an AST node, or a boxed <c>object?</c>. That is the
/// point: emitted CIL can call every one of these directly, and the compiler references
/// this library rather than the other way round.
/// </summary>
public static class Numbers
{
    /// <summary>
    /// Rounding, away from zero at a midpoint.
    ///
    /// <strong>Not what <c>Math.Round</c> does by default.</strong> .NET rounds a midpoint
    /// to even, so <c>Math.Round(2.5)</c> is 2 where Emerald answers 3 -- the rule every
    /// student has been taught, and the one every other beginner language uses. An emitter
    /// reaching for the obvious BCL call would have silently changed every <c>.5</c> in
    /// every program, which is why this is a named function rather than a habit.
    /// </summary>
    public static long Round(double value) =>
        (long)Math.Round(value, MidpointRounding.AwayFromZero);

    /// <summary>Rounding to a number of decimal places, by the same midpoint rule.</summary>
    public static double RoundTo(double value, int places) =>
        Math.Round(value, places, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Truncation toward zero, which is what <c>to_int</c> means and is not what
    /// <c>round</c> means. Kept beside it so the difference is visible at the definition
    /// rather than only at the call.
    /// </summary>
    public static long Truncate(double value) => (long)value;

    /// <summary>
    /// Integer division that floors, as <c>//</c> does.
    ///
    /// CIL's <c>div</c> truncates toward zero, so <c>-7 / 2</c> is -3 there and -4 here.
    /// The emitter must not reach for the bare opcode; it calls this, or inlines exactly
    /// what this does.
    /// </summary>
    public static long FloorDiv(long a, long b)
    {
        long quotient = a / b;
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient;
    }

    /// <summary>
    /// The remainder that matches <see cref="FloorDiv"/>, so <c>(a // b) * b + a % b</c>
    /// is <c>a</c> for every pair of signs. CIL's <c>rem</c> matches truncation instead.
    /// </summary>
    public static long FloorMod(long a, long b)
    {
        long rest = a % b;
        return (rest != 0 && (rest < 0) != (b < 0)) ? rest + b : rest;
    }

    /// <summary>
    /// A Float as Emerald writes it: whatever length reads back as the same value, a
    /// trailing <c>.0</c> on a whole one, and a lowercase <c>e</c> the scanner accepts.
    ///
    /// The large threshold is not arbitrary. Past 2^53 a double no longer holds every
    /// whole number, so printing one as a plain integer claims a precision it does not
    /// have; 1e16 is the first round power of ten beyond it. The small one follows
    /// Python, which switches at the same place.
    /// </summary>
    public static string Text(double d)
    {
        if (double.IsInfinity(d) || double.IsNaN(d))
            return d.ToString(CultureInfo.InvariantCulture);

        double size = Math.Abs(d);
        if (size != 0 && (size >= 1e16 || size < 1e-4)) return Scientific(d);

        // "R" and nothing else. A whole number formatted with "0.0" is fifteen significant
        // digits and therefore not round-trippable: 9007199254740992 printed as
        // 9007199254740990, a wrong answer to a value that had been typed exactly.
        string text = d.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.', StringComparison.Ordinal) ? text : text + ".0";
    }

    /// <summary>
    /// <c>1.0e-7</c> — the exponent form the scanner accepts, so the round trip closes.
    ///
    /// Built from "R" rather than from a fixed width. "E16" asks for seventeen digits
    /// whether or not they mean anything, so 0.0000001 came out as 9.9999999999999995e-8
    /// — true of the double, and not what anybody wrote or wants to read.
    /// </summary>
    private static string Scientific(double d)
    {
        string text = d.ToString("R", CultureInfo.InvariantCulture);

        int e = text.IndexOf('E', StringComparison.Ordinal);
        if (e >= 0)
        {
            string found = text[..e];
            if (!found.Contains('.', StringComparison.Ordinal)) found += ".0";
            return $"{found}e{int.Parse(text[(e + 1)..], CultureInfo.InvariantCulture)}";
        }

        // "R" switches to exponent form at its own threshold, not at this one, so 1e16
        // arrives here as seventeen plain digits. Where the two disagree, the language's
        // threshold wins and the point is placed here — by moving characters rather than
        // by arithmetic, so nothing is rounded on the way.
        bool negative = text.StartsWith('-');
        if (negative) text = text[1..];

        int point = text.IndexOf('.', StringComparison.Ordinal);
        string digits = point < 0 ? text : text.Remove(point, 1);
        if (point < 0) point = text.Length;

        int first = 0;
        while (first < digits.Length && digits[first] == '0') first++;
        if (first == digits.Length) return negative ? "-0.0" : "0.0";

        string significant = digits[first..].TrimEnd('0');
        string mantissa = significant.Length == 1
            ? significant + ".0"
            : significant[..1] + "." + significant[1..];

        return $"{(negative ? "-" : "")}{mantissa}e{point - first - 1}";
    }
}
