// Ui.cs — C-SAFE (Windows)
// Couleurs du logo C-FOCUS (bleu nuit, orange, cyan, crème) et petits éléments d'interface réutilisables.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace CSafe.App;

public static class Theme
{
    static SolidColorBrush B(uint hex) { var b = new SolidColorBrush(Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex)); b.Freeze(); return b; }
    public static readonly SolidColorBrush Background = B(0x0F1924), Panel = B(0x172636), Field = B(0x1D2D40), FieldHover = B(0x243850),
        Stroke = B(0x2B4058), Cream = B(0xF1EAD6), Muted = B(0x8FA6BD), Orange = B(0xE8742A), OrangeDark = B(0xC85A1C),
        Cyan = B(0x2A9FD6), Green = B(0x3CCB8F), Red = B(0xE5534B), OnOrange = B(0x1A0F06);
    public static SolidColorBrush Tint(SolidColorBrush b, double opacity)
    {
        var c = b.Color; var n = new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), c.R, c.G, c.B)); n.Freeze(); return n;
    }
    public static readonly FontFamily Sans = new("Segoe UI");
    public static readonly FontFamily Mono = new("Consolas");
    public static readonly FontFamily Icons = new("Segoe MDL2 Assets");
}

public static class Ui
{
    /// Nombre de menus ouverts : la fenêtre ne se redessine pas pendant qu'un menu est ouvert
    public static int OpenMenus;

    public static TextBlock T(string text, double size = 12, Brush? color = null, bool bold = false, bool mono = false,
                              bool wrap = false, bool semibold = false)
    {
        return new TextBlock
        {
            Text = text, FontSize = size, Foreground = color ?? Theme.Cream,
            FontWeight = bold ? FontWeights.Bold : semibold ? FontWeights.SemiBold : FontWeights.Normal,
            FontFamily = mono ? Theme.Mono : Theme.Sans,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    public static TextBlock Glyph(string glyph, double size = 12, Brush? color = null) => new()
    {
        Text = glyph, FontFamily = Theme.Icons, FontSize = size, Foreground = color ?? Theme.Cream,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static StackPanel Row(double spacing, params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(items[i]);
        }
        return p;
    }

    public static StackPanel Col(double spacing, params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Vertical };
        foreach (var it in items) Add(p, it, spacing);
        return p;
    }

    public static void Add(StackPanel p, UIElement it, double spacing)
    {
        if (it is FrameworkElement fe && p.Children.Count > 0) fe.Margin = new Thickness(fe.Margin.Left, fe.Margin.Top + spacing, fe.Margin.Right, fe.Margin.Bottom);
        p.Children.Add(it);
    }

    /// Encadré de section (titre en petites capitales + icône orange)
    public static Border PanelBox(string title, string icon, UIElement content)
    {
        var head = Row(6, Glyph(icon, 11, Theme.Orange), T(title.ToUpperInvariant(), 10.5, Theme.Muted, bold: true));
        var stack = new StackPanel();
        stack.Children.Add(head);
        if (content is FrameworkElement fe) fe.Margin = new Thickness(0, 8, 0, 0);
        stack.Children.Add(content);
        return new Border
        {
            Background = Theme.Panel, BorderBrush = Theme.Stroke, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Padding = new Thickness(11), Child = stack,
        };
    }

    /// Zone cliquable (bouton) au style C-SAFE
    public static Border Clickable(UIElement content, Action onClick, bool enabled = true, string? tooltip = null,
                                   Brush? background = null, Brush? hover = null, Brush? border = null, double radius = 7,
                                   Thickness? padding = null, double minHeight = 0)
    {
        var bg = background ?? Theme.Field;
        var b = new Border
        {
            Background = bg, BorderBrush = border ?? Theme.Stroke, BorderThickness = new Thickness(border == null && background != null ? 0 : 1),
            CornerRadius = new CornerRadius(radius), Padding = padding ?? new Thickness(10, 4, 10, 4), Child = content,
            Cursor = enabled ? Cursors.Hand : Cursors.Arrow, Opacity = enabled ? 1 : 0.45, MinHeight = minHeight,
            ToolTip = tooltip, SnapsToDevicePixels = true,
        };
        if (enabled)
        {
            b.MouseEnter += (_, _) => b.Background = hover ?? Theme.FieldHover;
            b.MouseLeave += (_, _) => b.Background = bg;
            b.MouseLeftButtonDown += (_, e) => { b.CaptureMouse(); e.Handled = true; };
            b.MouseLeftButtonUp += (_, e) =>
            {
                bool inside = b.IsMouseCaptured && b.IsMouseOver;
                b.ReleaseMouseCapture();
                e.Handled = true;
                if (inside) onClick();
            };
        }
        return b;
    }

    public static Border Secondary(string text, string? icon, Action onClick, bool enabled = true, string? tooltip = null)
    {
        var content = icon == null ? (UIElement)T(text, 12, Theme.Cream, semibold: true)
                                   : Row(6, Glyph(icon, 11, Theme.Cream), T(text, 12, Theme.Cream, semibold: true));
        var b = Clickable(content, onClick, enabled, tooltip, minHeight: 28);
        b.HorizontalAlignment = HorizontalAlignment.Left;
        return b;
    }

    public static Border Primary(string text, string icon, Action onClick, bool enabled = true)
    {
        var content = Row(8, Glyph(icon, 14, Theme.OnOrange), T(text, 14.5, Theme.OnOrange, bold: true));
        content.HorizontalAlignment = HorizontalAlignment.Center;
        return Clickable(content, onClick, enabled, background: Theme.Orange, hover: Theme.OrangeDark, radius: 9,
                         padding: new Thickness(10, 8, 10, 8));
    }

    /// Petit bouton icône (poubelle, éjecter…)
    public static Border IconButton(string glyph, Brush color, Action onClick, string tooltip, double size = 12)
    {
        var b = Clickable(Glyph(glyph, size, color), onClick, true, tooltip, background: Brushes.Transparent,
                          hover: Theme.Tint(Theme.Cream, 0.08), radius: 5, padding: new Thickness(4, 3, 4, 3));
        b.BorderThickness = new Thickness(0);
        return b;
    }

    // ---------------- Menus déroulants ----------------

    public sealed class MenuEntry
    {
        public string Text = "";
        public Action? Action;
        public bool Checked, Enabled = true, Header, Separator;
        public string? Glyph;
        public static MenuEntry Sep => new() { Separator = true };
        public static MenuEntry Title(string t) => new() { Text = t, Header = true, Enabled = false };
    }

    public static void OpenMenu(FrameworkElement anchor, IEnumerable<MenuEntry> entries)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom, FontFamily = Theme.Sans, FontSize = 12.5 };
        foreach (var e in entries)
        {
            if (e.Separator) { menu.Items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = e.Text, IsChecked = e.Checked, IsEnabled = e.Enabled && !e.Header };
            if (e.Header) { mi.FontStyle = FontStyles.Italic; mi.FontSize = 11.5; }
            if (e.Glyph != null && !e.Checked) mi.Icon = new TextBlock { Text = e.Glyph, FontFamily = Theme.Icons, FontSize = 12 };
            var act = e.Action;
            if (act != null) mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        OpenMenus++;
        menu.Closed += (_, _) => OpenMenus = Math.Max(0, OpenMenus - 1);
        menu.IsOpen = true;
    }

    /// Champ menu « valeur ⌄ »
    public static Border MenuField(string value, Func<IEnumerable<MenuEntry>> entries, bool enabled = true, string? tooltip = null,
                                   Brush? valueColor = null, double fontSize = 13, bool compact = false)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var t = T(value, fontSize, valueColor ?? Theme.Cream, semibold: true);
        var chev = Glyph("", 8, Theme.Muted);
        chev.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(chev, 1);
        g.Children.Add(t);
        g.Children.Add(chev);
        Border? b = null;
        b = Clickable(g, () => OpenMenu(b!, entries()), enabled, tooltip, padding: compact ? new Thickness(7, 2, 7, 2) : new Thickness(9, 4, 8, 4),
                      minHeight: compact ? 22 : 30);
        return b;
    }

    public static ProgressBar Bar(double value, Brush color) => new()
    {
        Minimum = 0, Maximum = 1, Value = Math.Clamp(value, 0, 1), Height = 5, Foreground = color,
        Background = Theme.Field, BorderThickness = new Thickness(0),
    };

    /// Interrupteur (case à cocher stylée)
    public static FrameworkElement Toggle(string text, bool value, Action<bool> onChange, double size = 12)
    {
        var knob = new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(6), Background = Theme.Cream, HorizontalAlignment = value ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(2) };
        var track = new Border { Width = 30, Height = 16, CornerRadius = new CornerRadius(8), Background = value ? Theme.Orange : Theme.Stroke, Child = knob, VerticalAlignment = VerticalAlignment.Center };
        var label = T(text, size, Theme.Cream, wrap: true);
        label.Margin = new Thickness(8, 0, 0, 0);
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(label, 1);
        g.Children.Add(track);
        g.Children.Add(label);
        var b = Clickable(g, () => onChange(!value), background: Brushes.Transparent, hover: Brushes.Transparent, padding: new Thickness(0));
        b.BorderThickness = new Thickness(0);
        return b;
    }
}
