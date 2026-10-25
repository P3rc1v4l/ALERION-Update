// Update Center - view model for the update list (compiled at runtime by Gui.ps1).
// A real class is needed because WPF only refreshes checkboxes/states through INotifyPropertyChanged.
using System.ComponentModel;

namespace Alerion
{
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
