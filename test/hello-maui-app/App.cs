// A real MAUI application running on the OpenHarmony platform slice.
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Controls.Shapes;
using Microsoft.Maui.Storage;

namespace HelloMauiApp;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        // The window hosts a flyout page (drawer) whose detail is a tabbed page; the main page
        // itself lives in a navigation page so the slice exercises every page type.
        => new Window(new FlyoutPage
        {
            Flyout = new ContentPage
            {
                Title = "Menu",
                Content = new VerticalStackLayout
                {
                    Padding = 24,
                    Spacing = 12,
                    Children =
                    {
                        new Label { Text = "Drawer", FontSize = 34 },
                        new Label { Text = "tap outside to close", FontSize = 22 },
                    },
                },
            },
            Detail = new TabbedPage
            {
                Children =
                {
                    new NavigationPage(BuildPage()) { Title = "Home", BarBackgroundColor = Colors.DarkSlateBlue },
                    new ContentPage { Title = "Animations", Content = BuildAnimationPage() },
                },
            },
        });

    private static View BuildAnimationPage()
    {
        var fadeTarget = new Label { Text = "animate me", FontSize = 36, HorizontalOptions = LayoutOptions.Center };
        var status = new Label { Text = "tap the button", FontSize = 26, HorizontalOptions = LayoutOptions.Center };
        var run = new Button { Text = "Run animations", FontSize = 32 };
        run.Clicked += async (_, _) =>
        {
            status.Text = "fading out...";
            await fadeTarget.FadeTo(0.1, 600, Easing.CubicInOut);
            await fadeTarget.FadeTo(1.0, 400, Easing.CubicInOut);
            await fadeTarget.TranslateTo(60, 0, 300, Easing.CubicOut);
            await fadeTarget.TranslateTo(0, 0, 300, Easing.CubicOut);
            await fadeTarget.RotateTo(360, 600, Easing.Linear);
            fadeTarget.Rotation = 0;
            status.Text = "animations done";
        };
        var carousel = new CarouselView
        {
            ItemsSource = new List<string> { "swipe A", "swipe B", "swipe C" },
            ItemTemplate = new DataTemplate(() =>
            {
                var slide = new Label { FontSize = 34, HorizontalOptions = LayoutOptions.Center };
                slide.SetBinding(Label.TextProperty, ".");
                return slide;
            }),
            HeightRequest = 160,
        };
        var positionLabel = new Label { Text = "swipe the carousel", FontSize = 24, HorizontalOptions = LayoutOptions.Center };
        carousel.PositionChanged += (_, _) => positionLabel.Text = $"slide {carousel.Position + 1}";
        return new VerticalStackLayout { Padding = 32, Spacing = 24, Children = { fadeTarget, carousel, positionLabel, run, status } };
    }

    private static ContentPage BuildPage()
    {
        // W22-13: Essentials - the counter survives restarts through Preferences.
        int clicks = Preferences.Get("demo.clicks", 0);
        var title = new Label { Text = "MAUI on OpenHarmony", FontSize = 44 };
        var subtitle = new Label { Text = "Microsoft.Maui.Controls through the platform slice", FontSize = 24 };
        var status = new Label { Text = "Tap the counter", FontSize = 28 };
        var counter = new Button { Text = $"Count: {clicks}", FontSize = 40 };
        counter.Clicked += (_, _) =>
        {
            clicks++;
            Preferences.Set("demo.clicks", clicks);
            counter.Text = $"Count: {clicks}";
            status.Text = $"last click #{clicks} (saved)";
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

        // W22-12: legacy ListView (cells) and a CarouselView.
        var legacyList = new ListView
        {
            ItemsSource = Enumerable.Range(0, 12).Select(i => $"legacy row {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cell = new TextCell();
                cell.SetBinding(TextCell.TextProperty, ".");
                return cell;
            }),
            HeightRequest = 200,
        };

        // W22-6: gesture recognizer (tap) + view transforms.
        int taps = 0;
        var tapTarget = new Label { Text = "tap this label (0 taps)", FontSize = 30, BackgroundColor = Colors.DimGray };
        var tapGesture = new TapGestureRecognizer();
        tapGesture.Tapped += (_, _) =>
        {
            taps++;
            tapTarget.Text = $"tap this label ({taps} taps)";
        };
        tapTarget.GestureRecognizers.Add(tapGesture);

        var reset = new Button { Text = "Reset", FontSize = 32 };
        reset.Clicked += (_, _) =>
        {
            clicks = 0;
            Preferences.Remove("demo.clicks");
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
        var pickerDemo = new Picker { Title = "pick", FontSize = 24 };
        pickerDemo.Items.Add("one");
        pickerDemo.Items.Add("two");
        pickerDemo.Items.Add("three");
        var valueRow2 = new HorizontalStackLayout { Spacing = 16 };
        valueRow2.Add(new Stepper { Minimum = 0, Maximum = 10, Increment = 1, Value = 1 });
        valueRow2.Add(new RadioButton { Content = "radio choice" });
        valueRow2.Add(new SearchBar { Placeholder = "search...", HeightRequest = 48 });
        valueRow2.Add(new DatePicker { Date = new DateTime(2026, 9, 17), FontSize = 24 });
        valueRow2.Add(new TimePicker { Time = new TimeSpan(14, 30, 0), FontSize = 24 });
        valueRow2.Add(pickerDemo);

        layout.Add(title);
        layout.Add(subtitle);
        layout.Add(counter);
        layout.Add(entry);
        layout.Add(valueControls);
        layout.Add(progress);
        layout.Add(shapeRow);
        layout.Add(borderBox);
        layout.Add(valueRow2);
        layout.Add(legacyList);
        layout.Add(collection);
        layout.Add(scroll);
        layout.Add(tapTarget);
        layout.Add(reset);
        layout.Add(status);
        return new ContentPage { Title = "MAUI on OpenHarmony", Content = layout };
    }
}
