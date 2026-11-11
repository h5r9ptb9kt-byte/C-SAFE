// MainWindow.cs — C-SAFE (Windows)
// Écran principal, même présentation que la version Mac : Tournage, Source → Destinations, Copie, Rapports, Journal.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CSafe.Core;
using static CSafe.App.Ui;

namespace CSafe.App;

public sealed class MainWindow : Window
{
    readonly AppState state;
    readonly StackPanel root = new() { Margin = new Thickness(10) };
    readonly ContentControl headerSlot = new(), shootDynamic = new(), transferSlot = new(), copySlot = new(), reportsSlot = new(), logSlot = new();
    readonly TextBox projectBox;
    readonly Border dateButton;
    readonly TextBlock dateText;
    readonly Popup datePopup;
    readonly Calendar calendar;
    bool dirty = true, dialogOpen, logExpanded;
    readonly DispatcherTimer redraw, projectDebounce;

    // Contrôles mis à jour en direct pendant la copie (sans tout redessiner)
    readonly Dictionary<string, (ProgressBar bar, TextBlock pct, TextBlock detail)> live = new();
    ProgressBar? globalBar;
    TextBlock? globalText;
    readonly List<TextBlock> destPct = new();
    TextBlock? dayReportCounter;

    public MainWindow()
    {
        Title = "C-SAFE";
        Width = 540; Height = 900; MinWidth = 420; MinHeight = 400;
        Background = Theme.Background;
        FontFamily = Theme.Sans;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        try { Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Assets/logo.png")); } catch { }
        if (SystemParameters.WorkArea.Height < 940) Height = SystemParameters.WorkArea.Height - 40;

        state = new AppState(Dispatcher);

        // ---- Champs permanents (jamais redessinés : on peut taper sans être interrompu) ----
        projectBox = new TextBox
        {
            Text = state.Project, FontSize = 13.5, Foreground = Theme.Cream, Background = Theme.Field, BorderBrush = Theme.Stroke,
            CaretBrush = Theme.Cream, Padding = new Thickness(6, 4, 6, 4), VerticalContentAlignment = VerticalAlignment.Center,
            SelectionBrush = Theme.Orange,
        };
        projectDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        projectDebounce.Tick += (_, _) => { projectDebounce.Stop(); state.Project = projectBox.Text; };
        projectBox.TextChanged += (_, _) => { projectDebounce.Stop(); projectDebounce.Start(); };
        projectBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) { projectDebounce.Stop(); state.Project = projectBox.Text; Keyboard.ClearFocus(); } };

        calendar = new Calendar { DisplayDateEnd = DateTime.Today, SelectedDate = DateTime.Today, FirstDayOfWeek = DayOfWeek.Monday };
        datePopup = new Popup { Child = calendar, StaysOpen = false, Placement = PlacementMode.Bottom, AllowsTransparency = true };
        calendar.SelectedDatesChanged += (_, _) =>
        {
            if (calendar.SelectedDate is DateTime d) { state.ShootDate = d; datePopup.IsOpen = false; }
            Mouse.Capture(null);
        };
        datePopup.Opened += (_, _) => OpenMenus++;
        datePopup.Closed += (_, _) => OpenMenus = Math.Max(0, OpenMenus - 1);
        dateText = T("", 13, Theme.Cream, semibold: true);
        dateButton = Clickable(Row(7, Glyph("", 12, Theme.Muted), dateText), () =>
        {
            if (state.Busy) return;
            calendar.DisplayDateEnd = DateTime.Today;
            calendar.SelectedDate = state.ShootDate;
            calendar.DisplayDate = state.ShootDate;
            datePopup.PlacementTarget = dateButton;
            datePopup.IsOpen = true;
        }, padding: new Thickness(9, 4, 9, 4), minHeight: 30);

        root.Children.Add(headerSlot);
        root.Children.Add(Spaced(BuildShootPanel()));
        root.Children.Add(Spaced(transferSlot));
        root.Children.Add(Spaced(copySlot));
        root.Children.Add(Spaced(reportsSlot));
        root.Children.Add(Spaced(logSlot));
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

        state.Changed += () => dirty = true;
        state.ProgressChanged += UpdateLive;
        redraw = new DispatcherTimer(TimeSpan.FromMilliseconds(150), DispatcherPriority.Background, (_, _) => Tick(), Dispatcher);
        redraw.Start();
        SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) dirty = true; };
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
            try { int dark = 1; DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)); } catch { }   // barre de titre sombre
        };
        Closing += (_, e) =>
        {
            if (state.Busy && MessageBox.Show(this, "Une copie est en cours. Quitter quand même ? La copie sera arrêtée et marquée « _INCOMPLET ».",
                "C-SAFE", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) e.Cancel = true;
            else { state.CancelCopy(); state.Save(); }
        };
        Rebuild();
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    static FrameworkElement Spaced(FrameworkElement e) { e.Margin = new Thickness(0, 8, 0, 0); return e; }

    public AppState State => state;

    // Branchement / débranchement d'un lecteur : on regarde tout de suite
    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int WM_DEVICECHANGE = 0x0219;
        if (msg == WM_DEVICECHANGE)
        {
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
            t.Tick += (_, _) => { t.Stop(); state.RefreshCards(); state.Refresh(); };
            t.Start();
        }
        return IntPtr.Zero;
    }

    void Tick()
    {
        if (dayReportCounter != null && state.MakingDayReport && state.DayReportStart is DateTime st)
            dayReportCounter.Text = $"Rapport du jour… {(int)(DateTime.Now - st).TotalSeconds} s / ≈ {state.DayReportEstimate} s";
        if (!dirty || OpenMenus > 0 || Mouse.LeftButton == MouseButtonState.Pressed) return;
        dirty = false;
        Rebuild();
        ShowDialogs();
    }

    void Rebuild()
    {
        live.Clear();
        destPct.Clear();
        headerSlot.Content = BuildHeader();
        shootDynamic.Content = BuildShootDynamic();
        transferSlot.Content = BuildTransfer();
        copySlot.Content = BuildCopy();
        reportsSlot.Content = BuildReports();
        logSlot.Content = BuildLog();
        dateText.Text = state.ShootDate.ToString("ddd d MMM yyyy", new System.Globalization.CultureInfo("fr-FR"));
        dateButton.Opacity = state.Busy ? 0.45 : 1;
        projectBox.IsEnabled = !state.Busy;
        if (!projectBox.IsKeyboardFocused && projectBox.Text != state.Project) projectBox.Text = state.Project;
    }

    void UpdateLive()
    {
        foreach (var (path, run) in state.Running)
        {
            if (!live.TryGetValue(path, out var c)) { dirty = true; continue; }
            c.bar.Value = Math.Clamp(run.Progress, 0, 1);
            c.pct.Text = $"{(int)(run.Progress * 100)} %";
            c.detail.Text = $"{run.Label} · {run.Text}";
        }
        if (globalBar != null) globalBar.Value = Math.Clamp(state.Progress, 0, 1);
        foreach (var t in destPct) t.Text = $"{(int)(state.Progress * 100)} %";
    }

    // ---------------- Messages (un à la fois) ----------------

    void ShowDialogs()
    {
        if (dialogOpen) return;
        dialogOpen = true;
        Dispatcher.BeginInvoke(() =>
        {
            try
            {
                while (true)
                {
                    if (state.Errors.Count > 0)
                    {
                        MessageBox.Show(this, state.Errors.Dequeue(), "C-SAFE", MessageBoxButton.OK, MessageBoxImage.Information);
                    }
                    else if (state.Duplicates.Count > 0)
                    {
                        var r = state.Duplicates.Dequeue();
                        if (MessageBox.Show(this, r.Message + "\n\nLa copier quand même sous un nouveau numéro ?", "Carte déjà déchargée",
                                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes)
                            state.ConfirmDuplicate(r);
                    }
                    else if (state.Failures.Count > 0)
                    {
                        var f = state.Failures.Dequeue();
                        if (MessageBox.Show(this, f.Message + "\n\nRecommencer maintenant ?", f.Title, MessageBoxButton.YesNo, MessageBoxImage.Warning,
                                MessageBoxResult.No) == MessageBoxResult.Yes)
                            state.Retry(f);
                    }
                    else if (updateOffer != null)
                    {
                        var u = updateOffer;
                        updateOffer = null;
                        if (MessageBox.Show(this, $"C-SAFE {u.Version} est disponible (tu as la {Updater.CurrentVersion}).\n\nC-SAFE va se fermer, s'installer puis se rouvrir tout seul. Tes réglages sont gardés.\n\nInstaller maintenant ?",
                                "Mise à jour disponible", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                            InstallUpdate(u);
                    }
                    else break;
                }
            }
            finally { dialogOpen = false; dirty = true; }
        });
    }

    // ---------------- En-tête ----------------

    bool checkingUpdate;
    Updater.Found? updateOffer;

    FrameworkElement BuildHeader()
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var logo = new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(18), BorderBrush = Theme.Cream, BorderThickness = new Thickness(1.5),
            ClipToBounds = true, VerticalAlignment = VerticalAlignment.Center,
        };
        try
        {
            logo.Background = new ImageBrush(new BitmapImage(new Uri("pack://application:,,,/Assets/logo.png"))) { Stretch = Stretch.UniformToFill };
        }
        catch { logo.Background = Theme.Orange; }
        var titles = Col(0, T("C-SAFE", 19, Theme.Cream, bold: true), T($"par C-FOCUS · v{Updater.CurrentVersion} · PC", 10.5, Theme.Orange, semibold: true));
        titles.Margin = new Thickness(9, 0, 0, 0);
        titles.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(titles, 1);
        var update = Secondary(checkingUpdate ? "Recherche…" : "Mise à jour", "", CheckUpdate, !state.Busy && !checkingUpdate,
                               "Installer la dernière version de C-SAFE pour Windows");
        var pillColor = state.Busy ? Theme.Orange : Theme.Green;
        var pill = new Border
        {
            Background = Theme.Tint(pillColor, 0.15), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 3, 8, 3),
            Child = Row(5, new Border { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = pillColor },
                        T(state.Busy ? "Copie" : "Prêt", 10.5, pillColor, semibold: true)),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0),
        };
        var right = Row(0, update, pill);
        Grid.SetColumn(right, 2);
        g.Children.Add(logo);
        g.Children.Add(titles);
        g.Children.Add(right);
        return g;
    }

    void CheckUpdate()
    {
        if (state.Busy) { state.Errors.Enqueue("Attends la fin des copies pour mettre à jour C-SAFE."); dirty = true; return; }
        checkingUpdate = true;
        dirty = true;
        state.AddLog("Recherche d'une mise à jour…");
        Task.Run(Updater.Check).ContinueWith(t => Dispatcher.BeginInvoke(() =>
        {
            checkingUpdate = false;
            var (found, error) = t.IsFaulted ? (null, t.Exception?.InnerException?.Message ?? "erreur inconnue") : t.Result;
            if (found != null && found.Build > Updater.CurrentBuild) updateOffer = found;
            else if (error != null) state.Errors.Enqueue("Mise à jour impossible : " + error);
            else
            {
                state.AddLog($"C-SAFE est à jour (version {Updater.CurrentVersion}).");
                state.Errors.Enqueue($"C-SAFE est à jour (version {Updater.CurrentVersion}).");
            }
            dirty = true;
        }));
    }

    void InstallUpdate(Updater.Found u)
    {
        if (state.Busy) { state.Errors.Enqueue("Attends la fin des copies pour mettre à jour C-SAFE."); return; }
        state.AddLog($"Téléchargement de la version {u.Version}…");
        checkingUpdate = true;
        dirty = true;
        state.Save();
        Task.Run(() => Updater.Install(u)).ContinueWith(t => Dispatcher.BeginInvoke(() =>
        {
            checkingUpdate = false;
            if (t.IsFaulted || t.Result != null) state.Errors.Enqueue("Mise à jour impossible : " + (t.Exception?.InnerException?.Message ?? t.Result));
            else Application.Current.Shutdown();
            dirty = true;
        }));
    }

    // ---------------- Tournage ----------------

    FrameworkElement BuildShootPanel()
    {
        var projRow = new Grid();
        projRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        projRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        projRow.Children.Add(T("Projet", 11, Theme.Muted, semibold: true));
        Grid.SetColumn(projectBox, 1);
        projRow.Children.Add(projectBox);
        var content = Col(8, projRow, shootDynamic);
        return PanelBox("Tournage", "", content);
    }

    FrameworkElement BuildShootDynamic()
    {
        var p = new StackPanel();
        var dateRow = new Grid();
        dateRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        dateRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        dateRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        dateRow.Children.Add(T("Date", 11, Theme.Muted, semibold: true));
        var mid = new StackPanel { Orientation = Orientation.Horizontal };
        if (dateButton.Parent is Panel old) old.Children.Remove(dateButton);
        mid.Children.Add(dateButton);
        if (state.IsToday)
        {
            var today = T("● Aujourd'hui", 11.5, Theme.Green, semibold: true);
            today.Margin = new Thickness(8, 0, 0, 0);
            mid.Children.Add(today);
        }
        else
        {
            var back = Secondary("Aujourd'hui", "", () => state.ShootDate = DateTime.Today, !state.Busy);
            back.Margin = new Thickness(6, 0, 0, 0);
            mid.Children.Add(back);
        }
        Grid.SetColumn(mid, 1);
        dateRow.Children.Add(mid);
        var badge = DayBadge();
        Grid.SetColumn(badge, 2);
        dateRow.Children.Add(badge);
        p.Children.Add(dateRow);
        Add(p, DayInfo(), 7);

        if (state.Done.Count > 0)
        {
            var wrap = new WrapPanel();
            wrap.Children.Add(new TextBlock { Text = "Faites :", FontSize = 10.5, Foreground = Theme.Muted, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 3) });
            foreach (var x in state.Done)
            {
                var nums = state.DoneNumbers.GetValueOrDefault(x) ?? new();
                var lt = state.LockedType(x);
                var model = string.IsNullOrEmpty(lt) ? "" : " " + lt;
                var text = nums.Count == 0 ? $"✓ {x}{model}" : $"✓ {x}{model} · n°" + string.Join(", ", nums);
                wrap.Children.Add(new Border
                {
                    Background = Theme.Tint(Theme.Green, 0.14), CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 2, 7, 2),
                    Margin = new Thickness(0, 0, 4, 3), Child = T(text, 10.5, Theme.Green, semibold: true),
                });
            }
            Add(p, wrap, 7);
        }
        return p;
    }

    FrameworkElement DayBadge()
    {
        var text = state.ShootDay is int j ? $"J{j}" : "J –";
        var content = Row(4, T(text, 14, Theme.Orange, bold: true));
        if (!state.DayExisting) content.Children.Add(new TextBlock { Text = "", FontFamily = Theme.Icons, FontSize = 8, Foreground = Theme.Orange, Margin = new Thickness(4, 2, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        var bg = Theme.Tint(Theme.Orange, state.DayManual ? 0.28 : 0.14);
        if (state.DayExisting)
        {
            return new Border
            {
                Background = bg, CornerRadius = new CornerRadius(7), Padding = new Thickness(11, 4, 11, 4), Child = content, MinHeight = 30,
                ToolTip = "Ce jour de tournage existe déjà sur les disques : les cartes s'y ajoutent", VerticalAlignment = VerticalAlignment.Center,
            };
        }
        Border? b = null;
        b = Clickable(content, () =>
        {
            var used = state.UsedDays;
            int maxN = Math.Max(15, (used.Count == 0 ? 0 : used.Keys.Max()) + 10);
            var entries = new List<MenuEntry>
            {
                new() { Text = $"Automatique (J{state.AutoShootDay})", Checked = !state.DayManual, Action = () => state.SetShootDay(null) },
                MenuEntry.Sep,
                MenuEntry.Title("Projet rejoint en cours de route"),
            };
            for (int n = 1; n <= maxN; n++)
            {
                int k = n;
                if (used.TryGetValue(k, out var d)) entries.Add(new() { Text = $"J{k} · déjà pris le {Naming.ShortDate(d)}", Enabled = false, Glyph = "" });
                else entries.Add(new() { Text = $"J{k}", Checked = state.DayManual && state.ShootDay == k, Action = () => state.SetShootDay(k) });
            }
            OpenMenu(b!, entries);
        }, !state.Busy, "Jour de tournage : automatique dans l'ordre des dates, ou choisi à la main (J3, J7…) si tu rejoins un projet en cours",
        background: bg, hover: Theme.Tint(Theme.Orange, 0.32), padding: new Thickness(11, 4, 11, 4), minHeight: 30);
        b.VerticalAlignment = VerticalAlignment.Center;
        return b;
    }

    FrameworkElement DayInfo()
    {
        int j = state.ShootDay ?? 1;
        if (state.DayManual)
            return T($"J{j} choisi à la main (projet rejoint en cours de route). Les jours suivants continueront à J{j + 1}, J{j + 2}…", 10.5, Theme.Muted, wrap: true);
        if (state.DayShift.Count == 0)
            return T(state.DayExisting ? $"J{j} : jour de tournage déjà commencé, les cartes s'y ajoutent."
                     : (j == 1 ? "J1 : premier jour de tournage du projet. Clique J1 pour choisir un autre numéro." : $"J{j} : nouveau jour de tournage (après J{j - 1})."),
                     10.5, Theme.Muted, wrap: true);
        var p = Col(5,
            Row(6, Glyph("", 12, Theme.Orange),
                T($"Le {Naming.ShortDate(state.DateString)} est avant " + string.Join(", ", state.DayShift.Select(x => $"J{x.J} ({Naming.ShortDate(x.Date)})")) + ".", 11.5, Theme.Orange, semibold: true, wrap: true)),
            T($"Pour garder l'ordre, ce jour devient J{j} et les jours suivants sont décalés sur tous les disques : " +
              string.Join(", ", state.DayShift.Select(x => $"J{x.J}→J{x.J + 1}")) + ".", 10.5, Theme.Cream, wrap: true),
            Secondary("Renuméroter les jours suivants", "", state.RenumberFollowingDays, !state.Busy));
        return new Border
        {
            Background = Theme.Tint(Theme.Orange, 0.10), BorderBrush = Theme.Tint(Theme.Orange, 0.5), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8), Padding = new Thickness(8), Child = p,
        };
    }

    // ---------------- Source → Destinations ----------------

    FrameworkElement BuildTransfer()
    {
        var src = SourceColumn();
        var dst = DestinationsColumn();
        bool wide = ActualWidth == 0 || ActualWidth >= 500;
        FrameworkElement body;
        var arrowColor = state.Busy ? Theme.Orange : Theme.Muted;
        var arrow = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Theme.Tint(arrowColor, 0.15),
            Child = new TextBlock { Text = wide ? "" : "", FontFamily = Theme.Icons, FontSize = 10, Foreground = arrowColor, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        if (wide)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            arrow.Margin = new Thickness(6, 24, 6, 0);
            arrow.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(arrow, 1);
            Grid.SetColumn(dst, 2);
            g.Children.Add(src);
            g.Children.Add(arrow);
            g.Children.Add(dst);
            body = g;
        }
        else
        {
            arrow.HorizontalAlignment = HorizontalAlignment.Left;
            arrow.Margin = new Thickness(8, 6, 0, 6);
            body = Col(0, src, arrow, dst);
        }
        return PanelBox("Source → Destinations", "", body);
    }

    static FrameworkElement ColumnTitle(string title, string icon) => Row(6, Glyph(icon, 11, Theme.Cream), T(title, 11.5, Theme.Cream, bold: true));

    FrameworkElement SourceColumn()
    {
        var p = new StackPanel();
        p.Children.Add(ColumnTitle("Source", ""));
        if (state.Cards.Count == 0)
        {
            Add(p, new Border
            {
                BorderBrush = Theme.Stroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(8),
                Child = T("Branche une carte : elle apparaît ici.", 11.5, Theme.Muted, wrap: true),
            }, 6);
        }
        foreach (var c in state.Cards) Add(p, CardRow(c), 6);
        if (state.IgnoredVolumes.Count > 0)
        {
            var l = Clickable(Row(5, Glyph("", 10, Theme.Muted), T($"{state.IgnoredVolumes.Count} disque(s) retiré(s) · Réafficher", 10.5, Theme.Muted)),
                              state.ShowIgnoredVolumes, background: Brushes.Transparent, hover: Theme.Tint(Theme.Cream, 0.06), padding: new Thickness(2));
            l.BorderThickness = new Thickness(0);
            l.HorizontalAlignment = HorizontalAlignment.Left;
            Add(p, l, 5);
        }
        Add(p, Secondary("Choisir une carte…", "", PickCard, !state.Busy), 6);
        return p;
    }

    void PickCard()
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Choisis la carte (sa lettre de lecteur) ou son dossier" };
        if (dlg.ShowDialog(this) == true) state.PickCard(dlg.FolderName);
    }

    FrameworkElement CardRow(CardVolume card)
    {
        var run = state.RunningCopyFor(card);
        bool isCopied = card.Previous != null;
        var p = new StackPanel();

        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var ic = Glyph("", 13, isCopied ? Theme.Green : (card.IsCamera ? Theme.Orange : Theme.Muted));
        ic.Margin = new Thickness(0, 2, 7, 0);
        ic.VerticalAlignment = VerticalAlignment.Top;
        top.Children.Add(ic);
        string subtitle = run != null ? "Copie en cours…"
            : card.Previous != null ? $"✓ Copiée et vérifiée : {card.Previous.Short}"
            : card.Analyzing ? (card.Detail.Length == 0 ? "" : card.Detail + " · ") + "analyse…"
            : !card.IsCamera ? "Pas une carte caméra"
            : card.Detail.Length == 0 ? "Carte caméra" : card.Detail;
        var names = Col(0, T(card.Name, 12.5, Theme.Cream, semibold: true), T(subtitle, 10.5, isCopied ? Theme.Green : Theme.Muted, wrap: true));
        Grid.SetColumn(names, 1);
        top.Children.Add(names);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        if (run != null)
        {
            var pct = T($"{(int)(run.Progress * 100)} %", 11.5, Theme.Orange, bold: true, mono: true);
            actions.Children.Add(pct);
            actions.Children.Add(IconButton("", Theme.Muted, () => state.CancelCopy(card), "Annuler la copie de cette carte"));
            var bar = Bar(run.Progress, Theme.Orange);
            var detail = T($"{run.Label} · {run.Text}", 9.5, Theme.Muted, mono: true);
            live[card.Path] = (bar, pct, detail);
            Grid.SetColumn(actions, 2);
            top.Children.Add(actions);
            p.Children.Add(top);
            Add(p, bar, 5);
            Add(p, detail, 3);
        }
        else
        {
            actions.Children.Add(IconButton("", Theme.Cyan, () => state.MakeDestination(card), "C'est un disque de sauvegarde : en faire une destination", 11));
            actions.Children.Add(IconButton("", Theme.Muted, () => state.IgnoreCard(card), "Retirer de la liste des sources (C-SAFE s'en souviendra)", 11));
            if (card.Ejectable)
            {
                var ej = Clickable(new TextBlock { Text = "⏏", FontFamily = new FontFamily("Segoe UI Symbol"), FontSize = 12, Foreground = Theme.Cream },
                                   () => state.EjectCard(card), true, "Éjecter la carte", Brushes.Transparent, Theme.Tint(Theme.Cream, 0.08), radius: 5, padding: new Thickness(4, 1, 4, 1));
                ej.BorderThickness = new Thickness(0);
                actions.Children.Add(ej);
            }
            Grid.SetColumn(actions, 2);
            top.Children.Add(actions);
            p.Children.Add(top);

            if (!isCopied)
            {
                var source = state.SourceFor(card);
                var (fresh, doneToday) = state.SourceChoices(card);
                bool isSound = Naming.IsSound(Naming.Label(source));
                var locked = isSound ? null : state.LockedType(source);
                var srcMenu = MenuField(source, () =>
                {
                    var e = new List<MenuEntry>();
                    if (doneToday.Count > 0)
                    {
                        e.Add(MenuEntry.Title("Déjà copiées ce jour — carte suivante"));
                        foreach (var d in doneToday) { var x = d; e.Add(new() { Text = state.NextCardText(x), Glyph = "", Action = () => state.Assign(x, card) }); }
                        e.Add(MenuEntry.Sep);
                    }
                    foreach (var f in fresh) { var x = f; e.Add(new() { Text = x, Checked = x == source, Action = () => state.Assign(x, card) }); }
                    e.Add(MenuEntry.Sep);
                    e.Add(new() { Text = "Autre…", Glyph = "", Action = () => AskName(true, card, source) });
                    if (!Naming.DefaultSources.Contains(source) && fresh.Contains(source))
                        e.Add(new() { Text = $"Retirer « {source} » de la liste", Glyph = "", Action = () => state.RemoveSource(source) });
                    return e;
                });
                var typeValue = isSound ? "—" : state.TypeFor(source);
                var typeMenu = MenuField(typeValue, () =>
                {
                    var e = new List<MenuEntry>();
                    if (locked != null) { e.Add(MenuEntry.Title($"🔒 {source} = {locked} aujourd'hui · autre modèle → nouvelle lettre")); e.Add(MenuEntry.Sep); }
                    foreach (var t in state.Types) { var x = t; e.Add(new() { Text = x, Checked = x == typeValue, Action = () => state.SetType(x, source, card) }); }
                    e.Add(MenuEntry.Sep);
                    e.Add(new() { Text = "Autre…", Glyph = "", Action = () => AskName(false, card, source) });
                    if (state.Types.Contains(typeValue))
                        e.Add(new() { Text = $"Retirer « {typeValue} » de la liste", Glyph = "", Action = () => state.RemoveType(typeValue) });
                    return e;
                }, enabled: !isSound && source != "—", tooltip: "Type de caméra");
                var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(typeMenu, 2);
                g.Children.Add(srcMenu);
                g.Children.Add(typeMenu);
                p.Children.Add(g);

                var preview = state.PreviewFor(card);
                if (preview.Length > 0)
                {
                    var pg = new Grid { Margin = new Thickness(0, 5, 0, 0) };
                    pg.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    pg.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    pg.Children.Add(Row(5, Glyph("", 10, Theme.Cyan), T(preview, 10.5, Theme.Cyan, semibold: true, mono: true)));
                    var num = CardNumberMenu(card);
                    Grid.SetColumn(num, 1);
                    pg.Children.Add(num);
                    p.Children.Add(pg);
                }
            }
        }
        return new Border
        {
            Background = Theme.Field, CornerRadius = new CornerRadius(8), Padding = new Thickness(7), Child = p,
            BorderBrush = run != null ? Theme.Orange : (isCopied ? Theme.Green : Brushes.Transparent), BorderThickness = new Thickness(1.2),
        };
    }

    FrameworkElement CardNumberMenu(CardVolume card)
    {
        var used = state.UsedCardNumbersFor(card);
        int auto = state.AutoCardNumber(card);
        int? chosen = state.CardNumber(card);
        int maxN = Math.Max(6, Math.Max((used.Count == 0 ? 0 : used.Max()) + 3, auto + 2));
        return MenuField($"n°{chosen ?? auto}", () =>
        {
            var e = new List<MenuEntry> { new() { Text = $"Automatique (n°{auto})", Checked = chosen == null, Action = () => state.SetCardNumber(null, card) }, MenuEntry.Sep };
            for (int n = 1; n <= maxN; n++)
            {
                int k = n;
                if (used.Contains(k)) e.Add(new() { Text = $"Carte n°{k} · déjà copiée", Enabled = false, Glyph = "" });
                else e.Add(new() { Text = $"Carte n°{k}", Checked = chosen == k, Action = () => state.SetCardNumber(k, card) });
            }
            return e;
        }, tooltip: "Numéro de la carte : automatique, ou choisi pour garder l'ordre de tournage (ex. carte n°2 copiée avant la n°1)",
           valueColor: chosen == null ? Theme.Cream : Theme.Orange, fontSize: 11.5, compact: true);
    }

    void AskName(bool source, CardVolume card, string forSource)
    {
        var name = Dialogs.Ask(this, source ? "Nouvelle source" : "Nouveau type de caméra",
                               source ? "Ex. Drone, GoPro-Casque, Plateau" : "Ex. FX6, Mavic 3, Alexa");
        if (string.IsNullOrWhiteSpace(name)) return;
        if (source) state.AddSource(name, card); else state.AddType(name, forSource, card);
    }

    FrameworkElement DestinationsColumn()
    {
        var p = new StackPanel();
        p.Children.Add(ColumnTitle("Destinations", ""));
        int i = 0;
        foreach (var d in state.Destinations.ToList())
        {
            i++;
            bool ok = state.IsReachable(d);
            var col = ok ? Theme.Cyan : Theme.Red;
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var num = new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Theme.Tint(col, 0.15), Margin = new Thickness(0, 0, 7, 0),
                Child = new TextBlock { Text = i.ToString(), FontSize = 10.5, FontWeight = FontWeights.Bold, Foreground = col, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            };
            g.Children.Add(num);
            var names = Col(0, T(d.Name, 12.5, Theme.Cream, semibold: true), T(ok ? state.FreeSpace(d) : "Introuvable — branche le disque", 10.5, ok ? Theme.Muted : Theme.Red));
            names.ToolTip = d.Path;
            Grid.SetColumn(names, 1);
            g.Children.Add(names);
            FrameworkElement right;
            if (state.Busy)
            {
                var t = T($"{(int)(state.Progress * 100)} %", 11.5, Theme.Orange, bold: true, mono: true);
                destPct.Add(t);
                right = t;
            }
            else
            {
                var dd = d;
                right = IconButton("", Theme.Muted, () => state.RemoveDestination(dd), "Retirer ce disque", 11);
            }
            Grid.SetColumn(right, 2);
            g.Children.Add(right);
            Add(p, new Border { Background = Theme.Field, CornerRadius = new CornerRadius(8), Padding = new Thickness(7), Child = g }, 6);
        }
        Add(p, Secondary("Ajouter un disque", "", AddDestination, !state.Busy), 6);
        if (state.Destinations.Count < 2)
            Add(p, T(state.Destinations.Count == 0 ? "Ajoute 2 disques : chaque carte y est copiée en même temps." : "⚠ Ajoute un 2e disque pour être en sécurité.",
                     10.5, Theme.Orange, wrap: true), 5);
        return p;
    }

    void AddDestination()
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Choisis le disque (ou le dossier) de sauvegarde" };
        if (dlg.ShowDialog(this) == true) state.AddDestination(dlg.FolderName);
    }

    // ---------------- Copie ----------------

    FrameworkElement BuildCopy()
    {
        var p = new StackPanel();
        string icon = state.Busy ? "" : state.LastSuccess switch { true => "", false => "", _ => "" };
        var color = state.Busy ? Theme.Orange : state.LastSuccess switch { true => Theme.Green, false => Theme.Red, _ => Theme.Muted };
        p.Children.Add(Row(7, Glyph(icon, 13, color), T(state.Status, 12.5, Theme.Cream, semibold: true, wrap: true)));
        globalBar = null;
        if (state.Busy || state.LastSuccess != null)
        {
            globalBar = Bar(state.Progress, state.LastSuccess == true ? Theme.Green : state.LastSuccess == false ? Theme.Red : Theme.Orange);
            Add(p, globalBar, 6);
            Add(p, T(state.Busy ? $"{state.Running.Count} copie(s) en cours — détail sur chaque carte" : state.ProgressText, 10.5, Theme.Muted, mono: true), 3);
        }
        Add(p, VerifyRow(), 8);
        Add(p, Primary("Démarrer la copie", "", state.StartCopy), 9);
        Add(p, T("Rien n'est copié tant que tu n'as pas cliqué « Démarrer la copie ». Chaque nouvelle carte attend ton clic.", 10.5, Theme.Muted, wrap: true), 6);
        var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (state.Busy) g.Children.Add(Secondary(state.Running.Count > 1 ? "Tout annuler" : "Annuler", "", state.CancelCopy));
        var ej = Toggle("Éjecter à la fin", state.Eject, v => { state.Eject = v; dirty = true; }, 11.5);
        Grid.SetColumn(ej, 1);
        g.Children.Add(ej);
        p.Children.Add(g);
        if (state.ParallelInfo.Length > 0) Add(p, T(state.ParallelInfo, 10, Theme.Muted, wrap: true), 4);
        return PanelBox("Copie", "", p);
    }

    FrameworkElement VerifyRow()
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var shield = Glyph("", 13, Theme.Green);
        shield.VerticalAlignment = VerticalAlignment.Top;
        shield.Margin = new Thickness(0, 1, 7, 0);
        g.Children.Add(shield);
        var texts = Col(2, T("Vérification toujours active : chaque fichier est relu sur chaque disque et comparé à la carte.", 10.5, Theme.Cream, wrap: true),
                        T($"{state.HashKind.Title()} : {state.HashKind.Explanation()}", 10.5, Theme.Muted, wrap: true));
        Grid.SetColumn(texts, 1);
        g.Children.Add(texts);
        var menu = MenuField(state.HashKind.Title(), () => new[] { HashKind.Xxh64, HashKind.Md5 }.Select(k =>
            new MenuEntry { Text = $"{k.Title()} — {k.Explanation()}", Checked = state.HashKind == k, Action = () => state.HashKind = k }),
            !state.Busy, "Empreinte de vérification : xxHash64 (rapide, recommandé) ou MD5 (si la production l'exige)", fontSize: 11.5, compact: true);
        menu.VerticalAlignment = VerticalAlignment.Top;
        menu.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(menu, 2);
        g.Children.Add(menu);
        return g;
    }

    // ---------------- Rapports ----------------

    FrameworkElement BuildReports()
    {
        var p = new StackPanel();
        p.Children.Add(Toggle("PDF à chaque carte : vignettes, timecode, durée, résolution, codec, empreintes", state.MakePDF, v => state.MakePDF = v, 11.5));
        if (state.LastReport is string u)
        {
            Add(p, Row(6, Glyph("", 12, Theme.Orange), T(Path.GetFileName(u), 10.5, Theme.Cream, mono: true)), 7);
            Add(p, Row(6, Secondary("Ouvrir le PDF", "", () => state.OpenReport(u)),
                        Secondary("Afficher dans l'Explorateur", "", () => state.RevealReport(u))), 6);
        }
        int cards = state.DayReportCards;
        dayReportCounter = null;
        if (state.MakingDayReport && state.DayReportStart is DateTime st)
        {
            dayReportCounter = T($"Rapport du jour… {(int)(DateTime.Now - st).TotalSeconds} s / ≈ {state.DayReportEstimate} s", 12, Theme.Cream, semibold: true);
            var b = Clickable(Row(6, Glyph("", 11, Theme.Cream), dayReportCounter), () => { }, false);
            b.Opacity = 1;
            b.HorizontalAlignment = HorizontalAlignment.Left;
            Add(p, b, 8);
        }
        else
        {
            Add(p, Secondary($"Rapport du jour {(state.ShootDay is int j ? $"J{j}" : "")} : toutes les cartes en un PDF", "", state.MakeDayReport,
                             !state.Busy && !state.MakingDayReport && cards > 0), 8);
        }
        Add(p, T(cards == 0
                ? "À faire le soir, quand toutes les cartes du jour sont copiées. Aucune carte avec rapport pour ce jour sur le premier disque."
                : $"À faire le soir : {cards} carte(s) prête(s) · environ {state.DayReportEstimate} s (les vignettes sont déjà faites). Le PDF de chaque carte, lui, se fait tout seul après sa copie.",
                10.5, Theme.Muted, wrap: true), 6);
        Add(p, T("Dans Rapports_de_copie : le PDF à lire, le .mhl (standard DIT, relu par Silverstack, ShotPut, Hedge) et le .txt. Les fichiers techniques sont rangés dans le sous-dossier masqué .C-SAFE.",
                 10.5, Theme.Muted, wrap: true), 5);
        return PanelBox("Rapports", "", p);
    }

    // ---------------- Journal (replié par défaut) ----------------

    static Brush LineColor(string text) =>
        text.StartsWith("✓") ? Theme.Green : text.StartsWith("✗") || text.StartsWith("⚠") ? Theme.Red
        : text.StartsWith("→") || text.StartsWith("Carte détectée") ? Theme.Orange : Theme.Cream;

    FrameworkElement BuildLog()
    {
        var p = new StackPanel();
        var head = Row(6, Glyph(logExpanded ? "" : "", 9, Theme.Muted), T("JOURNAL", 10.5, Theme.Muted, bold: true));
        if (!logExpanded && state.Log.Count > 0)
        {
            var last = state.Log[^1].Text;
            head.Children.Add(new TextBlock { Text = last, FontSize = 10.5, FontFamily = Theme.Mono, Foreground = LineColor(last), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        }
        var hb = Clickable(head, () => { logExpanded = !logExpanded; dirty = true; }, background: Brushes.Transparent, hover: Brushes.Transparent, padding: new Thickness(0));
        hb.BorderThickness = new Thickness(0);
        p.Children.Add(hb);
        if (logExpanded)
        {
            var lines = new StackPanel();
            foreach (var (time, text) in state.Log.TakeLast(60).Reverse())
            {
                var g = new Grid { Margin = new Thickness(0, 1, 0, 1) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(62) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.Children.Add(T(time, 10.5, Theme.Tint(Theme.Muted, 0.8), mono: true));
                var tt = T(text, 10.5, LineColor(text), mono: true, wrap: true);
                Grid.SetColumn(tt, 1);
                g.Children.Add(tt);
                lines.Children.Add(g);
            }
            Add(p, new ScrollViewer { Content = lines, Height = 170, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 6);
        }
        return new Border
        {
            Background = Theme.Panel, BorderBrush = Theme.Stroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(9), Child = p,
        };
    }

    // ---------------- Capture d'écran automatique (tests sur la machine Windows de GitHub) ----------------

    public void SaveScreenshot(string path, bool expandLog = false)
    {
        logExpanded = expandLog;
        Rebuild();
        UpdateLayout();
        var el = (FrameworkElement)root;
        el.Measure(new Size(ActualWidth > 0 ? ActualWidth - 20 : 520, double.PositiveInfinity));
        var w = Math.Max(1, (int)Math.Ceiling(el.ActualWidth + 20));
        var h = Math.Max(1, (int)Math.Ceiling(el.DesiredSize.Height + 20));
        var bmp = new RenderTargetBitmap(w * 2, h * 2, 192, 192, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var ctx = dv.RenderOpen())
        {
            ctx.DrawRectangle(Theme.Background, null, new Rect(0, 0, w, h));
            ctx.DrawRectangle(new VisualBrush(el) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }, null,
                              new Rect(10, 10, el.ActualWidth, el.ActualHeight));
        }
        bmp.Render(dv);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
    }
}
