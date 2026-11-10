using System.Runtime.InteropServices;
using System.Windows;

namespace Inlay.Windows;

internal static class DictationClipboard
{
    // Called on the WPF dispatcher. Never read the clipboard or send a paste shortcut.
    internal static bool TryCopy(string text)
    {
        try { Clipboard.SetText(text); return true; }
        catch (ExternalException) { return false; } // another app can hold the clipboard open
    }
}
