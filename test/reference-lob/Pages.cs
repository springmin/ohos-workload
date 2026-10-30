// Dashboard, orders list, form, and settings pages. Code-only UI; the chart is a GraphicsView
// drawable (no Skia, no native dependency).
using Microsoft.Maui.ApplicationModel;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Graphics;
using Microsoft.Maui.Platform;
using Microsoft.Maui.Storage;
using Microsoft.OpenHarmony.Hosting;

namespace ReferenceLob;

public sealed class DashboardPage : ContentPage
{
    private readonly Label _revenue = new() { Text = "€ 128,400", FontSize = 24, FontAttributes = FontAttributes.Bold };
    private readonly ChartDrawable _chart = new(new[] { 42f, 58f, 51f, 73f, 66f, 88f, 79f });

    public DashboardPage()
    {
        Title = "Dashboard";
        var refresh = new Button { Text = "Refresh metrics" };
        refresh.Clicked += (_, _) =>
        {
            int n = Random.Shared.Next(90, 160);
            _revenue.Text = $"€ {n},{(n * 7) % 1000:000}";
            _chart.Values = Enumerable.Range(0, 7).Select(_ => (float)Random.Shared.Next(30, 95)).ToArray();
            ((GraphicsView)_chartView!).Invalidate();
        };

        _chartView = new GraphicsView { HeightRequest = 180, Drawable = _chart };

        Content = new ScrollView
        {
            Content = new VerticalStackLayout
            {
                Padding = new Thickness(24),
                Spacing = 16,
                Children =
                {
                    new Label { Text = $"Welcome, {AppState.User}", FontSize = 20, FontAttributes = FontAttributes.Bold },
                    new Label { Text = "OpenHarmony reference application", TextColor = Colors.DimGray },
                    Card("Revenue (MTD)", _revenue, Color.FromArgb("#1B6EF3")),
                    new Border
                    {
                        Padding = 16,
                        StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 12 },
                        BackgroundColor = Color.FromArgb("#F4F6FB"),
                        Content = new VerticalStackLayout
                        {
                            Spacing = 8,
                            Children =
                            {
                                new Label { Text = "Weekly throughput", FontAttributes = FontAttributes.Bold },
                                _chartView,
                            },
                        },
                    },
                    refresh,
                },
            },
        };
    }

    private GraphicsView? _chartView;

    private static Border Card(string title, Label value, Color accent) => new()
    {
        Padding = 16,
        StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 12 },
        BackgroundColor = accent.WithAlpha(0.10f),
        Content = new VerticalStackLayout
        {
            Spacing = 4,
            Children =
            {
                new Label { Text = title, TextColor = accent, FontAttributes = FontAttributes.Bold },
                value,
            },
        },
    };
}

public sealed class ListPage : ContentPage
{
    private readonly CollectionView _collection;
    private readonly Label _status = new() { TextColor = Colors.DimGray, FontSize = 13 };
    private readonly Label _selected = new() { Text = "No order selected", FontSize = 13 };
    private Item? _current;

    public ListPage()
    {
        Title = "Orders";
        var search = new SearchBar { Placeholder = "Filter 1,000 orders" };
        search.TextChanged += (_, e) => ApplyFilter(e.NewTextValue);

        _collection = new CollectionView
        {
            SelectionMode = SelectionMode.Single,
            ItemTemplate = new DataTemplate(() =>
            {
                var name = new Label { FontSize = 15, FontAttributes = FontAttributes.Bold, LineBreakMode = LineBreakMode.TailTruncation };
                var meta = new Label { FontSize = 12, TextColor = Colors.DimGray };
                var cell = new Grid
                {
                    Padding = new Thickness(12, 8),
                    ColumnDefinitions =
                    {
                        new ColumnDefinition(GridLength.Star),
                        new ColumnDefinition(GridLength.Auto),
                    },
                };
                cell.Add(name, 0, 0);
                cell.Add(meta, 1, 0);
                cell.BindingContextChanged += (_, _) =>
                {
                    if (cell.BindingContext is Item item)
                    {
                        name.Text = item.Name;
                        meta.Text = $"#{item.Id:000} · {item.Status} · €{item.Amount}";
                    }
                };
                return cell;
            }),
        };
        _collection.SelectionChanged += (_, e) =>
        {
            if (e.CurrentSelection.FirstOrDefault() is Item item)
            {
                _current = item;
                _selected.Text = $"Selected: {item.Name} (#{item.Id})";
                OpenHarmonyBridge.WriteStatus($"[ref] selected {item.Id}");
            }
        };

        var openWindow = new Button { Text = "Open detail in subwindow" };
        openWindow.Clicked += (_, _) => OpenDetailWindow();
        var closeWindow = new Button { Text = "Close detail window", BackgroundColor = Color.FromArgb("#E8ECF4") };
        closeWindow.Clicked += (_, _) =>
        {
            bool closed = OpenHarmonySubWindow.Close();
            _status.Text = closed ? "Detail window closed." : "No detail window to close.";
        };

        _collection.ItemsSource = AppState.Items;

        Content = new Grid
        {
            RowDefinitions =
            {
                new RowDefinition(GridLength.Auto),
                new RowDefinition(GridLength.Auto),
                new RowDefinition(GridLength.Star),
                new RowDefinition(GridLength.Auto),
                new RowDefinition(GridLength.Auto),
            },
            Padding = new Thickness(20),
            RowSpacing = 8,
            Children =
            {
                search,
                _selected,
                _collection,
                _status,
                new HorizontalStackLayout
                {
                    Spacing = 8,
                    Children = { openWindow, closeWindow },
                },
            },
        };
        Grid.SetRow(search, 0);
        Grid.SetRow(_selected, 1);
        Grid.SetRow(_collection, 2);
        Grid.SetRow(_status, 3);
        Grid.SetRow((View)((Grid)Content).Children[4], 4);
    }

    private void ApplyFilter(string? text)
    {
        IReadOnlyList<Item> source = AppState.Items;
        if (!string.IsNullOrWhiteSpace(text))
        {
            source = source.Where(i =>
                i.Name.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                i.Status.Contains(text, StringComparison.OrdinalIgnoreCase)).ToList();
        }
        _collection.ItemsSource = source;
        _status.Text = $"{source.Count} of {AppState.Items.Count} orders";
    }

    private void OpenDetailWindow()
    {
        if (!OpenHarmonySubWindow.IsSupported)
        {
            _status.Text = "Subwindow not supported by this shell.";
            return;
        }
        if (_current is null)
        {
            _status.Text = "Select an order first.";
            return;
        }
        bool created = OpenHarmonySubWindow.Create(
            $"reference-detail-{_current.Id}", 120, 160, 760, 480, $"Order #{_current.Id:000} · {_current.Status}");
        _status.Text = created
            ? $"Detail window requested for #{_current.Id:000}."
            : "Subwindow create failed.";
        OpenHarmonyBridge.WriteStatus($"[ref] subwindow create={created} item={_current.Id}");
    }
}

public sealed class FormPage : ContentPage
{
    private readonly Entry _name = new() { Placeholder = "Contact name" };
    private readonly Entry _email = new() { Placeholder = "name@company.com", Keyboard = Keyboard.Email };
    private readonly Editor _notes = new() { Placeholder = "Requirement notes", HeightRequest = 110 };
    private readonly Picker _priority = new() { Title = "Priority" };
    private readonly Switch _notify = new() { IsToggled = true };
    private readonly Label _status = new() { FontSize = 13, TextColor = Colors.DimGray };

    public FormPage()
    {
        Title = "Form";
        _priority.Items.Add("Low");
        _priority.Items.Add("Normal");
        _priority.Items.Add("High");
        _priority.SelectedIndex = 1;

        var save = new Button { Text = "Save (JSON)" };
        save.Clicked += (_, _) => SaveForm();

        Content = new ScrollView
        {
            Content = new VerticalStackLayout
            {
                Padding = new Thickness(24),
                Spacing = 10,
                Children =
                {
                    new Label { Text = "New request", FontSize = 22, FontAttributes = FontAttributes.Bold },
                    new Label { Text = "Name" },
                    _name,
                    new Label { Text = "Email" },
                    _email,
                    new Label { Text = "Priority" },
                    _priority,
                    new Label { Text = "Notes" },
                    _notes,
                    new HorizontalStackLayout
                    {
                        Spacing = 10,
                        Children = { _notify, new Label { Text = "Notify me by email", VerticalOptions = LayoutOptions.Center } },
                    },
                    save,
                    _status,
                },
            },
        };
    }

    protected override void OnAppearing()
    {
        base.OnAppearing();
        if (ReferenceStore.LoadForm() is { } saved)
        {
            _name.Text = saved.Name;
            _email.Text = saved.Email;
            _notes.Text = saved.Notes;
            _priority.SelectedItem = saved.Priority;
            _notify.IsToggled = saved.Notify;
            _status.Text = $"Loaded {ReferenceStore.FormPath}";
        }
    }

    private void SaveForm()
    {
        if (string.IsNullOrWhiteSpace(_name.Text))
        {
            _status.Text = "Name is required.";
            _status.TextColor = Colors.Firebrick;
            return;
        }
        if (string.IsNullOrWhiteSpace(_email.Text) || !_email.Text.Contains('@', StringComparison.Ordinal))
        {
            _status.Text = "A valid email is required.";
            _status.TextColor = Colors.Firebrick;
            return;
        }

        var data = new FormData(
            _name.Text.Trim(),
            _email.Text.Trim(),
            _notes.Text?.Trim() ?? string.Empty,
            _priority.SelectedItem as string ?? "Normal",
            _notify.IsToggled);
        try
        {
            ReferenceStore.SaveForm(data);
            _status.Text = $"Saved to {ReferenceStore.FormPath}";
            _status.TextColor = Colors.SeaGreen;
            OpenHarmonyBridge.WriteStatus("[ref] form saved");
        }
        catch (Exception ex)
        {
            _status.Text = $"Save failed: {ex.GetType().Name}";
            _status.TextColor = Colors.Firebrick;
        }
    }
}

public sealed class SettingsPage : ContentPage
{
    public SettingsPage()
    {
        Title = "Settings";
        var dark = new Switch { IsToggled = Application.Current?.UserAppTheme == AppTheme.Dark };
        dark.Toggled += (_, e) =>
        {
            if (Application.Current is { } app)
            {
                app.UserAppTheme = e.Value ? AppTheme.Dark : AppTheme.Light;
            }
        };

        var logout = new Button { Text = "Sign out" };
        logout.Clicked += async (_, _) =>
        {
            await Navigation.PushModalAsync(new LoginPage());
        };

        Content = new ScrollView
        {
            Content = new VerticalStackLayout
            {
                Padding = new Thickness(24),
                Spacing = 12,
                Children =
                {
                    new Label { Text = "Settings", FontSize = 22, FontAttributes = FontAttributes.Bold },
                    Row("Dark theme", dark),
                    Row("Version", new Label { Text = "Reference LOB 1.0 · MAUI 11 rc.2" }),
                    Row("Data", new Label { Text = ReferenceStore.FormPath, FontSize = 12, TextColor = Colors.DimGray }),
                    Row("User", new Label { Text = AppState.User }),
                    logout,
                    new Label
                    {
                        Text = "Deep links: app://reference/dashboard | orders | form | settings",
                        FontSize = 12,
                        TextColor = Colors.DimGray,
                    },
                },
            },
        };
    }

    private static HorizontalStackLayout Row(string label, View control) => new()
    {
        Spacing = 12,
        Children =
        {
            new Label { Text = label, WidthRequest = 110, VerticalOptions = LayoutOptions.Center },
            control,
        },
    };
}
