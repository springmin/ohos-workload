// Login lifecycle probe: a single ContentPage whose host ContentView is swapped between a
// "main" view and a login view (entries or labels-only). No page/tab/modal/navigation, no deep
// links. An automatic sequence runs on Loaded and logs every step; if the process exits, the
// last step names the trigger. Buttons are provided for manual runs.
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Graphics;
using Microsoft.OpenHarmony.Hosting;

namespace LoginProbe;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new(new ProbePage());
}

public sealed class ProbePage : ContentPage
{
    private readonly ContentView _host = new() { HorizontalOptions = LayoutOptions.Fill, VerticalOptions = LayoutOptions.Fill };
    private readonly Label _status = new() { FontSize = 13, TextColor = Colors.DimGray };
    private readonly MainProbeView _main = new();
    private int _step;

    public ProbePage()
    {
        var entries = new Button { Text = "Login: entries" };
        entries.Clicked += (_, _) => ShowLogin(true);
        var labels = new Button { Text = "Login: labels" };
        labels.Clicked += (_, _) => ShowLogin(false);
        var main = new Button { Text = "Main" };
        main.Clicked += (_, _) => ShowMain();

        var top = new HorizontalStackLayout
        {
            Spacing = 8,
            Padding = new Thickness(20, 12),
            Children = { entries, labels, main },
        };

        Content = new Grid
        {
            RowDefinitions =
            {
                new RowDefinition(GridLength.Auto),
                new RowDefinition(GridLength.Star),
                new RowDefinition(GridLength.Auto),
            },
            Children = { top, _host, _status },
        };
        Grid.SetRow(top, 0);
        Grid.SetRow(_host, 1);
        Grid.SetRow(_status, 2);

        ShowMain();
        Loaded += (_, _) =>
        {
            OpenHarmonyBridge.WriteStatus("[probe] loaded; auto sequence start");
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(1000), () => ShowLogin(true));
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(3500), () => ShowMain());
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(6000), () => ShowLogin(false));
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(8500), () => ShowMain());
            Dispatcher.DispatchDelayed(TimeSpan.FromMilliseconds(11000), () =>
            {
                _status.Text = "auto sequence done";
                OpenHarmonyBridge.WriteStatus("[probe] auto sequence done");
            });
        };
    }

    private void ShowMain()
    {
        _step++;
        _status.Text = $"step {_step}: main";
        OpenHarmonyBridge.WriteStatus($"[probe] step={_step} main");
        _host.Content = _main;
    }

    private void ShowLogin(bool withEntries)
    {
        _step++;
        _status.Text = $"step {_step}: login {(withEntries ? "entries" : "labels")}";
        OpenHarmonyBridge.WriteStatus($"[probe] step={_step} login-{(withEntries ? "entries" : "labels")}");
        _host.Content = new LoginProbeView(withEntries);
    }
}

public sealed class MainProbeView : ContentView
{
    public MainProbeView()
    {
        Content = new VerticalStackLayout
        {
            Padding = 24,
            Spacing = 12,
            Children =
            {
                new Label { Text = "Main content", FontSize = 24, FontAttributes = FontAttributes.Bold },
                new Label { Text = "This view contains no Entry controls." },
                new Label { Text = "The login views are swapped into the same host ContentView." },
            },
        };
    }
}

public sealed class LoginProbeView : ContentView
{
    public LoginProbeView(bool withEntries)
    {
        var stack = new VerticalStackLayout
        {
            Padding = 24,
            Spacing = 10,
            Children =
            {
                new Label { Text = $"Login ({(withEntries ? "entries" : "labels only")})", FontSize = 22, FontAttributes = FontAttributes.Bold },
            },
        };

        if (withEntries)
        {
            stack.Add(new Label { Text = "Email" });
            stack.Add(new Entry { Placeholder = "name@company.com", Keyboard = Keyboard.Email });
            stack.Add(new Label { Text = "Password" });
            stack.Add(new Entry { Placeholder = "password", IsPassword = true });
        }
        else
        {
            stack.Add(new Label { Text = "No Entry controls on this surface." });
        }

        var signIn = new Button { Text = "Sign in" };
        signIn.Clicked += (_, _) => OpenHarmonyBridge.WriteStatus("[probe] sign-in clicked");
        stack.Add(signIn);
        Content = stack;
    }
}
