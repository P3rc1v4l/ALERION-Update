// Update Center - view model for the update list (compiled at runtime by Gui.ps1).
// A real class is needed because WPF only refreshes checkboxes/states through INotifyPropertyChanged.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Alerion
{
    // Borderless WPF windows maximize over the whole monitor (taskbar included).
    // Answering WM_GETMINMAXINFO with the monitor's work area keeps the taskbar visible.
    public static class WindowFix
    {
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct MINMAXINFO { public POINT reserved, maxSize, maxPosition, minTrackSize, maxTrackSize; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)] class MONITORINFO { public int cbSize = Marshal.SizeOf(typeof(MONITORINFO)); public RECT monitor; public RECT work; public int flags; }
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, int flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, [In, Out] MONITORINFO info);

        static readonly HwndSourceHook hook = Hook;   // static field keeps the delegate alive

        public static void Attach(IntPtr hwnd) { HwndSource.FromHwnd(hwnd).AddHook(hook); }

        static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg != 0x0024) return IntPtr.Zero;   // WM_GETMINMAXINFO
            IntPtr monitor = MonitorFromWindow(hwnd, 2 /* MONITOR_DEFAULTTONEAREST */);
            if (monitor == IntPtr.Zero) return IntPtr.Zero;
            MONITORINFO info = new MONITORINFO();
            if (!GetMonitorInfo(monitor, info)) return IntPtr.Zero;
            MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
            mmi.maxPosition.x = info.work.left - info.monitor.left;
            mmi.maxPosition.y = info.work.top - info.monitor.top;
            mmi.maxSize.x = info.work.right - info.work.left;
            mmi.maxSize.y = info.work.bottom - info.work.top;
            Marshal.StructureToPtr(mmi, lParam, true);
            return IntPtr.Zero;
        }
    }

    // Generic row for the Programs / Cleanup / Security lists.
    public class ListRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Raise(string name) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        public object Data { get; set; }
        public string Key { get; set; }
        public string Title { get; set; }
        public string Subtitle { get; set; }
        public string Right { get; set; }          // size / version column
        public double SortValue { get; set; }      // numeric sort (e.g. size)
        public string Badge { get; set; }
        public string BadgeBrush { get; set; }
        public string Glyph { get; set; }
        public string GlyphBrush { get; set; }
        public bool Locked { get; set; }           // protected program / unavailable category
        public string ActionText { get; set; }
        public string Uri { get; set; }

        bool selected; public bool Selected { get { return selected; } set { if (selected != value) { selected = value; Raise("Selected"); } } }
        string detail; public string Detail { get { return detail; } set { detail = value; Raise("Detail"); } }
        string state; public string State { get { return state; } set { state = value; Raise("State"); } }
        string stateBrush; public string StateBrush { get { return stateBrush; } set { stateBrush = value; Raise("StateBrush"); } }
        bool busy; public bool Busy { get { return busy; } set { busy = value; Raise("Busy"); } }
    }

    public class UpdateRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        void Raise(string name) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        public string Key { get; set; }
        public string Source { get; set; }
        public string SourceLabel { get; set; }
        public string Name { get; set; }
        public string Id { get; set; }
        public string From { get; set; }
        public string To { get; set; }
        public string Status { get; set; }
        public string Priority { get; set; }
        public string PriorityLabel { get; set; }
        public string PriorityBrush { get; set; }
        public bool IsCheck { get; set; }
        public bool Major { get; set; }
        public bool IsUpdate { get; set; }
        public bool CanExclude { get; set; }
        public string MajorLabel { get; set; }

        public bool HasVersions { get { return !string.IsNullOrEmpty(From) || !string.IsNullOrEmpty(To); } }
        public bool ShowArrow { get { return !string.IsNullOrEmpty(From) && !string.IsNullOrEmpty(To) && From != To; } }

        string note; public string Note { get { return note; } set { note = value; Raise("Note"); } }
        string group; public string GroupLabel { get { return group; } set { group = value; Raise("GroupLabel"); } }
        int rank; public int GroupRank { get { return rank; } set { rank = value; Raise("GroupRank"); } }
        bool excluded; public bool Excluded { get { return excluded; } set { excluded = value; Raise("Excluded"); Raise("Selectable"); } }
        string excludeTip; public string ExcludeTip { get { return excludeTip; } set { excludeTip = value; Raise("ExcludeTip"); } }
        string excludeGlyph; public string ExcludeGlyph { get { return excludeGlyph; } set { excludeGlyph = value; Raise("ExcludeGlyph"); } }

        public bool Selectable { get { return IsUpdate && !excluded; } }

        bool selected; public bool Selected { get { return selected; } set { if (selected != value) { selected = value; Raise("Selected"); } } }
        string state; public string State { get { return state; } set { state = value; Raise("State"); } }
        string stateText; public string StateText { get { return stateText; } set { stateText = value; Raise("StateText"); } }
        string stateBrush; public string StateBrush { get { return stateBrush; } set { stateBrush = value; Raise("StateBrush"); } }
    }
}
