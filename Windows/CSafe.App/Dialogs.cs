// Dialogs.cs — C-SAFE (Windows) : petite fenêtre « Nouveau nom » (source ou type de caméra)

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using static CSafe.App.Ui;

namespace CSafe.App;

public static class Dialogs
{
    public static string? Ask(Window owner, string title, string hint)
    {
        string? result = null;
        var w = new Window
        {
            Title = title, Owner = owner, Width = 360, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Theme.Panel, ShowInTaskbar = false,
            FontFamily = Theme.Sans,
        };
        var box = new TextBox
        {
            FontSize = 13.5, Foreground = Theme.Cream, Background = Theme.Field, BorderBrush = Theme.Stroke, CaretBrush = Theme.Cream,
            Padding = new Thickness(6, 4, 6, 4), SelectionBrush = Theme.Orange,
        };
        void Ok() { result = box.Text.Trim(); w.DialogResult = true; }
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Ok(); if (e.Key == Key.Escape) w.DialogResult = false; };
        var buttons = Row(8, Secondary("Annuler", null, () => w.DialogResult = false), Secondary("Ajouter", "", Ok));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var content = Col(8,
            T(title, 14, Theme.Cream, bold: true),
            T(hint, 11, Theme.Muted, wrap: true),
            box,
            T("Il restera dans la liste pour les prochaines fois.", 10.5, Theme.Muted, wrap: true),
            buttons);
        content.Margin = new Thickness(16);
        w.Content = content;
        w.Loaded += (_, _) => box.Focus();
        return w.ShowDialog() == true && !string.IsNullOrWhiteSpace(result) ? result : null;
    }
}
