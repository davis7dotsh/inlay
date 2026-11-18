using System.IO;
using System.Runtime.InteropServices;
using System.Windows;

namespace Inlay.Windows;

internal static class DictationClipboard
{
    // Called on the WPF dispatcher. Never read the clipboard or send a paste shortcut.
    internal static bool TryCopy(string text)
    {
        try
        {
            var data = new DataObject();
            data.SetText(text.ReplaceLineEndings("\r\n"), TextDataFormat.UnicodeText);
            // Windows reads these registered formats as DWORDs. Flush them with the text
            // so Ctrl+V still works after exit without opting into Win+V or cloud sync.
            using var history = new MemoryStream(new byte[sizeof(uint)]);
            using var cloud = new MemoryStream(new byte[sizeof(uint)]);
            data.SetData("CanIncludeInClipboardHistory", history, autoConvert: false);
            data.SetData("CanUploadToCloudClipboard", cloud, autoConvert: false);
            Clipboard.SetDataObject(data, copy: true);
            return true;
        }
        catch (ExternalException) { return false; } // another app can hold the clipboard open
    }
}
