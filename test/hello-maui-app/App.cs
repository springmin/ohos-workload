// A real MAUI application running on the OpenHarmony platform slice.
using Microsoft.Maui;
using Microsoft.Maui.Controls;

namespace HelloMauiApp;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        // The page is hosted in a navigation page: the slice draws the bar and its back button.
        => new Window(new NavigationPage(BuildPage()) { Title = "Home", BarBackgroundColor = Colors.DarkSlateBlue });

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
        // W22-1: soft-keyboard text input through the ArkTS shell's TextInput.
        var entry = new Entry { Placeholder = "type here (soft keyboard)", FontSize = 32 };
        entry.TextChanged += (_, e) => status.Text = $"text: '{e.NewTextValue}'";
        entry.Completed += (_, _) => status.Text = "entry completed";

        // W22-2: value controls (checkbox, switch, slider, progress, spinner).
        var checkBox = new CheckBox { IsChecked = true };
        var toggle = new Switch { IsToggled = false };
        var slider = new Slider { Minimum = 0, Maximum = 100, Value = 40, HeightRequest = 40 };
        var progress = new ProgressBar { Progress = 0.4, HeightRequest = 8 };
        var spinner = new ActivityIndicator { IsRunning = true, HeightRequest = 24 };
        checkBox.CheckedChanged += (_, e) => status.Text = $"checkbox: {e.Value}";
        toggle.Toggled += (_, e) => status.Text = $"switch: {e.Value}";
        slider.ValueChanged += (_, e) =>
        {
            progress.Progress = e.NewValue / 100.0;
            status.Text = $"slider: {e.NewValue:0}";
        };
        var valueControls = new HorizontalStackLayout { Spacing = 16 };
        valueControls.Add(checkBox);
        valueControls.Add(toggle);
        valueControls.Add(slider);
        valueControls.Add(spinner);

        // W21: clip + translate scrolling, driven by touch drags.
        var rows = new VerticalStackLayout { Spacing = 8 };
        for (int i = 0; i < 12; i++)
        {
            rows.Add(new Label { Text = $"scrollable row {i}", FontSize = 26 });
        }
        var scroll = new ScrollView { Content = rows, HeightRequest = 320 };

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
        layout.Add(entry);
        layout.Add(valueControls);
        layout.Add(progress);
        layout.Add(scroll);
        layout.Add(reset);
        layout.Add(status);
        return new ContentPage { Title = "MAUI on OpenHarmony", Content = layout };
    }
}
