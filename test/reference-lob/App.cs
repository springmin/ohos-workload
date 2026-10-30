// App shell: mock login, a four-tab main surface, and the deep-link router. All UI is built in
// code so the sample exercises handlers, not XAML compilation.
using Microsoft.Maui.ApplicationModel;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Graphics;
using Microsoft.OpenHarmony.Hosting;

namespace ReferenceLob;

public sealed class App : Application
{
    public App()
    {
        OpenHarmonyBridge.LifecycleChanged += e => OpenHarmonyBridge.WriteStatus($"[ref] lifecycle {e}");
    }

    protected override Window CreateWindow(IActivationState? activationState)
        => new(new MainTabs());

    public static void HandleActivation(OpenHarmonyActivationEventArgs e)
    {
        string uri = e.Uri ?? string.Empty;
        OpenHarmonyBridge.WriteStatus($"[ref] activation uri='{uri}' action='{e.Action}'");
        const string prefix = "app://reference/";
        if (!uri.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        string route = uri.Substring(prefix.Length).Trim('/');
        if (route.Length == 0)
        {
            route = "dashboard";
        }

        MainThread.BeginInvokeOnMainThread(async () =>
        {
            if (Current?.Windows.FirstOrDefault()?.Page is not MainTabs tabs)
            {
                OpenHarmonyBridge.WriteStatus("[ref] activation: main tabs not ready");
                return;
            }
            tabs.Navigate(route);
            while (tabs.Navigation.ModalStack.Count > 0)
            {
                await tabs.Navigation.PopModalAsync();
            }
        });
    }
}

public static class AppState
{
    public static string User { get; set; } = "demo@springmin.com";
    public static List<Item> Items { get; } = CreateItems();

    private static List<Item> CreateItems()
    {
        string[] names =
        {
            "Aluminium housing", "Bearing kit", "Cable harness", "Drive unit", "Encoder board",
            "Filter cartridge", "Gear box", "Heatsink", "Inspection lamp", "Junction box",
        };
        string[] statuses = { "Open", "In progress", "Blocked", "Done" };
        var items = new List<Item>(1000);
        for (int i = 1; i <= 1000; i++)
        {
            items.Add(new Item(i, $"{names[i % names.Length]} #{i:000}", statuses[i % statuses.Length], 25 + (i * 7 % 900)));
        }
        return items;
    }
}

public sealed record Item(int Id, string Name, string Status, int Amount);

public sealed class LoginPage : ContentPage
{
    public LoginPage()
    {
        Title = "Reference LOB";
        var email = new Entry { Placeholder = "name@company.com", Text = AppState.User, Keyboard = Keyboard.Email };
        var password = new Entry { Placeholder = "password", IsPassword = true, Text = "demo" };
        var status = new Label { TextColor = Colors.Firebrick, FontSize = 13 };
        var signIn = new Button { Text = "Sign in" };
        signIn.Clicked += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(email.Text) || !email.Text.Contains('@', StringComparison.Ordinal))
            {
                status.Text = "Enter a valid email address.";
                return;
            }
            if (string.IsNullOrWhiteSpace(password.Text))
            {
                status.Text = "Enter a password.";
                return;
            }
            AppState.User = email.Text.Trim();
            if (Navigation.ModalStack.Count > 0)
            {
                await Navigation.PopModalAsync();
            }
        };

        Content = new ScrollView
        {
            Content = new VerticalStackLayout
            {
                Padding = new Thickness(32),
                Spacing = 14,
                Children =
                {
                    new Label { Text = "Reference LOB", FontSize = 28, FontAttributes = FontAttributes.Bold },
                    new Label { Text = "MAUI on OpenHarmony · reference application", TextColor = Colors.DimGray },
                    new Label { Text = "Email", FontAttributes = FontAttributes.Bold, Margin = new Thickness(0, 12, 0, 0) },
                    email,
                    new Label { Text = "Password", FontAttributes = FontAttributes.Bold },
                    password,
                    status,
                    signIn,
                    new Label
                    {
                        Text = "Mock sign-in: any valid email + non-empty password.",
                        FontSize = 12,
                        TextColor = Colors.DimGray,
                    },
                },
            },
        };
    }
}

public sealed class MainTabs : TabbedPage
{
    private readonly DashboardPage _dashboard = new();
    private readonly ListPage _orders = new();
    private readonly FormPage _form = new();
    private readonly SettingsPage _settings = new();

    public MainTabs()
    {
        Title = "Reference LOB";
        Children.Add(_dashboard);
        Children.Add(_orders);
        Children.Add(_form);
        Children.Add(_settings);
        CurrentPage = _dashboard;
        OpenHarmonyBridge.WriteStatus($"[ref] main tabs: {Children.Count}");
    }

    public void Navigate(string route)
    {
        Page target = route.ToLowerInvariant() switch
        {
            "orders" or "list" => _orders,
            "form" => _form,
            "settings" => _settings,
            _ => _dashboard,
        };
        CurrentPage = target;
        OpenHarmonyBridge.WriteStatus($"[ref] navigate '{route}' -> {target.Title}");
    }
}
