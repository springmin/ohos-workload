// A real MAUI application running on the OpenHarmony platform slice.
using Microsoft.Maui;
using Microsoft.Maui.Controls;

namespace HelloMauiApp;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new Window(BuildPage());

    private static ContentPage BuildPage()
    {
        int clicks = 0;
        var title = new Label { Text = "MAUI on OpenHarmony", FontSize = 44 };
        var subtitle = new Label { Text = "Microsoft.Maui.Controls through the platform slice", FontSize = 24 };
        var status = new Label { Text = "Tap the counter", FontSize = 28 };
        var counter = new Button { Text = "Count: 0", FontSize = 40 };
        counter.Clicked += (_, _) =>
        {
            clicks++;
            counter.Text = $"Count: {clicks}";
            status.Text = $"last click #{clicks}";
        };
        var reset = new Button { Text = "Reset", FontSize = 32 };
        reset.Clicked += (_, _) =>
        {
            clicks = 0;
            counter.Text = "Count: 0";
            status.Text = "reset";
        };

        var layout = new VerticalStackLayout { Padding = 32, Spacing = 20 };
        layout.Add(title);
        layout.Add(subtitle);
        layout.Add(counter);
        layout.Add(reset);
        layout.Add(status);
        return new ContentPage { Content = layout };
    }
}
