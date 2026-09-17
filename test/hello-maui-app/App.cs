// A real MAUI application running on the OpenHarmony platform slice.
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Controls.Shapes;

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

        // W22-4: collection view (items materialized from a template, drag-scrollable).
        var collection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 30).Select(i => $"collection item {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 26 };
                itemLabel.SetBinding(Label.TextProperty, ".");
                return itemLabel;
            }),
            HeightRequest = 260,
        };

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
        // W22-5: shapes, border, stepper, radio button, search bar.
        var shapeRow = new HorizontalStackLayout { Spacing = 12 };
        shapeRow.Add(new Rectangle { WidthRequest = 48, HeightRequest = 48, Fill = Colors.OrangeRed, Stroke = Colors.White, StrokeThickness = 2 });
        shapeRow.Add(new Ellipse { WidthRequest = 48, HeightRequest = 48, Fill = Colors.MediumSeaGreen });
        shapeRow.Add(new Line { X1 = 0, Y1 = 0, X2 = 48, Y2 = 48, Stroke = Colors.Gold, StrokeThickness = 3 });
        var borderBox = new Border
        {
            Stroke = Colors.DodgerBlue,
            StrokeThickness = 3,
            Padding = 10,
            Content = new Label { Text = "inside border", FontSize = 24 },
        };
        var valueRow2 = new HorizontalStackLayout { Spacing = 16 };
        valueRow2.Add(new Stepper { Minimum = 0, Maximum = 10, Increment = 1, Value = 1 });
        valueRow2.Add(new RadioButton { Content = "radio choice" });
        valueRow2.Add(new SearchBar { Placeholder = "search...", HeightRequest = 48 });

        layout.Add(title);
        layout.Add(subtitle);
        layout.Add(counter);
        layout.Add(entry);
        layout.Add(valueControls);
        layout.Add(progress);
        layout.Add(shapeRow);
        layout.Add(borderBox);
        layout.Add(valueRow2);
        layout.Add(collection);
        layout.Add(scroll);
        layout.Add(reset);
        layout.Add(status);
        return new ContentPage { Title = "MAUI on OpenHarmony", Content = layout };
    }
}
