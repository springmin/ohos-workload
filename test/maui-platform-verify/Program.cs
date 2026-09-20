using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;

// A small image file for the Image handler.
string imagePath = Path.Combine(Path.GetTempPath(), "verify-image.png");
File.WriteAllBytes(imagePath, Convert.FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));

gestures.Drawable = new ProbeDrawable();
OpenHarmonyWindowRenderer.SurfaceBegin = (_, _) => true;
OpenHarmonyWindowRenderer.SurfacePresent = () => { };
var builder = MauiApp.CreateBuilder();
builder.UseOpenHarmony();
builder.UseMauiApp<TestApp>();
var app = builder.Build();
var host = app.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
host.Run(app.Services.GetRequiredService<IApplication>());

var navRoot = (NavigationPage)host.Window!.Content;
var page = (ContentPage)navRoot.CurrentPage;
var root = (VerticalStackLayout)page.Content!;
Console.WriteLine($"[verify] nav state: stack={navRoot.Navigation.NavigationStack.Count} current={(navRoot.CurrentPage?.GetType().Name ?? "null")} currentHandler={navRoot.CurrentPage?.Handler?.GetType().Name ?? "null"} layoutHandler={root.Handler?.GetType().Name ?? "null"} pageFrame={page.Frame}");


// Window handler + lifecycle (no platform window required now).
var window = host.Window;
Console.WriteLine($"[verify] window handler={window.Handler?.GetType().Name ?? "null"}");
try
{
    window.Handler?.Invoke("Created");
    Console.WriteLine("[verify] window Created() ok");
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] window Created() threw {ex.GetType().Name}: {ex.Message}");
}

host.Arrange(1080, 1920);
Console.WriteLine($"[verify] after arrange: root={root.Frame} page={page.Frame} nav={navRoot.Frame}");
Console.WriteLine(host.Describe().Split('\n').Skip(1).FirstOrDefault());

// Tap the entry -> focus; drag the scroll view -> offset changes.
var entry = root.Children.OfType<Entry>().FirstOrDefault();
if (entry is not null)
{
    Rect entryFrame = entry.Frame;
    bool d = host.HandleTouch(true, false, (float)(entryFrame.X + 10), (float)(entryFrame.Y + 10));
    bool u = host.HandleTouch(false, true, (float)(entryFrame.X + 10), (float)(entryFrame.Y + 10));
    var entryPlatform = (OpenHarmonyView)entry.Handler!.PlatformView!;
    Console.WriteLine($"[verify] entry tap handled(down={d}, up={u}) platformFocused={entryPlatform.IsFocused} virtualFocused={entry.IsFocused}");
}

var scroll = root.Children.OfType<ScrollView>().FirstOrDefault();
if (scroll is not null)
{
    Rect scrollFrame = scroll.Frame;
    float sx = (float)(scrollFrame.X + scrollFrame.Width / 2);
    bool sd = host.HandleTouch(true, false, sx, (float)(scrollFrame.Y + 40));
    bool m1 = host.HandleMove(sx, (float)(scrollFrame.Y + 10));
    bool m2 = host.HandleMove(sx, (float)(scrollFrame.Y - 30));
    bool su = host.HandleTouch(false, true, sx, (float)(scrollFrame.Y - 30));
    Console.WriteLine($"[verify] scroll drag handled(down={sd}, move1={m1}, move2={m2}, up={su})");
    Console.WriteLine($"[verify] scroll offsetY={((IScrollView)scroll).VerticalOffset:0} (virtual view)");
    Console.WriteLine($"[verify] after drag: {host.Describe().Split('\n').FirstOrDefault(l => l.Contains("scroll="))?.Trim()}");
}


// W22-7: animation (MAUI ticker), picker dropdown, tabbed page.
var fadeCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "fade me");
if (fadeCtl is not null)
{
    var fadeTask = fadeCtl.FadeTo(0.25, 120, Easing.Linear);
    if (await Task.WhenAny(fadeTask, Task.Delay(3000)) != fadeTask)
    {
        Console.WriteLine($"[verify] FadeTo did not finish (opacity={fadeCtl.Opacity:0.##})");
    }
    else
    {
        Console.WriteLine($"[verify] FadeTo completed opacity={fadeCtl.Opacity:0.##}");
    }
    await fadeCtl.FadeTo(1.0, 60, Easing.Linear);
}

var pickerTest = root.Children.OfType<Picker>().FirstOrDefault();
if (pickerTest is not null && pickerTest.Handler?.PlatformView is OpenHarmonyView pickerPlatform)
{
    Rect f = pickerTest.Frame;
    host.HandleTouch(true, false, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] picker popup visible={pickerPlatform.PopupVisible} items={pickerPlatform.PopupItems.Count}");
    float popupItemY = (float)(f.Y + f.Height + OpenHarmonyView.PopupRowHeight * 2 + OpenHarmonyView.PopupRowHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + 20), popupItemY);
    host.HandleTouch(false, true, (float)(f.X + 20), popupItemY);
    Console.WriteLine($"[verify] picker selected index={pickerTest.SelectedIndex} text='{pickerPlatform.Text}' popup={pickerPlatform.PopupVisible}");
}

// W22-9: async image source resolves into the platform view.
await Task.Delay(200);
var streamCtl = root.Children.OfType<Image>().FirstOrDefault(i => i.Source is StreamImageSource);
if (streamCtl?.Handler?.PlatformView is OpenHarmonyView streamPlatform)
{
    Console.WriteLine($"[verify] stream image bytes={streamPlatform.ImageBytes?.Length ?? 0}");
}

// W22-8: date/time picker dropdowns.
var dateCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<DatePicker>().FirstOrDefault();
if (dateCtl is not null && dateCtl.Handler?.PlatformView is OpenHarmonyView datePlatform)
{
    Rect f = dateCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] datepicker open={datePlatform.PopupVisible} month={datePlatform.CalendarYear}-{datePlatform.CalendarMonth:00} selected={datePlatform.CalendarSelectedDay}");
    // Tap "next month" (>), then a day in the shown month.
    float headerY = (float)(f.Y + f.Height + OpenHarmonyView.CalendarHeaderHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + OpenHarmonyView.CalendarWidth - 20), headerY);
    host.HandleTouch(false, true, (float)(f.X + OpenHarmonyView.CalendarWidth - 20), headerY);
    int day = 15;
    int leading = ((int)new DateTime(datePlatform.CalendarYear, datePlatform.CalendarMonth, 1).DayOfWeek + 6) % 7;
    int cell = leading + day - 1;
    float cellX = (float)(f.X + (cell % 7) * (OpenHarmonyView.CalendarWidth / 7f) + OpenHarmonyView.CalendarWidth / 14f);
    float cellY = (float)(f.Y + f.Height + OpenHarmonyView.CalendarHeaderHeight + ((cell / 7) + 1) * OpenHarmonyView.CalendarRowHeight + OpenHarmonyView.CalendarRowHeight / 2);
    host.HandleTouch(true, false, cellX, cellY);
    host.HandleTouch(false, true, cellX, cellY);
    Console.WriteLine($"[verify] datepicker after calendar tap date={dateCtl.Date:yyyy-MM-dd} text='{datePlatform.Text}' popup={datePlatform.PopupVisible}");
}

var timeCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<TimePicker>().FirstOrDefault();
if (timeCtl is not null && timeCtl.Handler?.PlatformView is OpenHarmonyView timePlatform)
{
    Rect f = timeCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    float rowY = (float)(f.Y + f.Height + OpenHarmonyView.PopupRowHeight * 30 + OpenHarmonyView.PopupRowHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + 10), rowY);
    host.HandleTouch(false, true, (float)(f.X + 10), rowY);
    Console.WriteLine($"[verify] timepicker time={timeCtl.Time:hh\\:mm} text='{timePlatform.Text}' popup={timePlatform.PopupVisible}");
}

// W22-22: Shell.GoToAsync route navigation.
Microsoft.Maui.Controls.Routing.RegisterRoute("verifyDetail", typeof(RoutedPage));
var shellForRoute = new Shell();
shellForRoute.Items.Add(new ShellContent { Title = "Home", ContentTemplate = new DataTemplate(() => new ContentPage { Title = "Home", Content = new Label { Text = "home" } }) });
OpenHarmonyHandlerConnector.ConnectTree(shellForRoute);
shellForRoute.Measure(1080, 1920);
shellForRoute.Arrange(new Rect(0, 0, 1080, 1920));
try
{
    await shellForRoute.GoToAsync("verifyDetail");
    await Task.Delay(150);
    var routePlatform = (OpenHarmonyView)shellForRoute.Handler!.PlatformView!;
    routePlatform.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell route current='{shellForRoute.CurrentPage?.Title}' chrome='{routePlatform.TitleText}' back={routePlatform.ShowsBack}");
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] shell route threw {ex.GetType().Name}: {ex.Message}");
}

// W22-10: Shell.
var rendererForShell = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var shellOne = new ContentPage { Title = "First", Content = new Label { Text = "shell one" } };
var shellTwo = new ContentPage { Title = "Second", Content = new Label { Text = "shell two" } };
var shell = new Shell();
shell.Items.Add(new ShellContent { Title = "First", ContentTemplate = new DataTemplate(() => shellOne) });
shell.Items.Add(new ShellContent { Title = "Second", ContentTemplate = new DataTemplate(() => shellTwo) });
OpenHarmonyHandlerConnector.ConnectTree(shell);
shell.Measure(1080, 1920);
shell.Arrange(new Rect(0, 0, 1080, 1920));
if (shell.Handler?.PlatformView is OpenHarmonyView shellPlatform)
{
    Console.WriteLine($"[verify] shell titles=[{string.Join(",", shellPlatform.TabTitles)}] selected={shellPlatform.SelectedTab} current='{shell.CurrentPage?.Title}'");
    double sy = shell.Frame.Height - OpenHarmonyView.TabBarHeight / 2;
    rendererForShell.HandleTouch(shell, true, false, (float)(shell.Frame.Width * 0.75), (float)sy);
    rendererForShell.HandleTouch(shell, false, true, (float)(shell.Frame.Width * 0.75), (float)sy);
    Console.WriteLine($"[verify] shell after tab tap selected={shellPlatform.SelectedTab} current='{shell.CurrentPage?.Title}' label={((shell.CurrentPage as ContentPage)?.Content as Label)?.Frame}");
    Console.WriteLine($"[verify] shell chrome title='{shellPlatform.TitleText}' back={shellPlatform.ShowsBack} hamburger={shellPlatform.ShowsHamburger}");
    var shellSection = shell.CurrentItem!.CurrentItem!;
    await shellSection.Navigation.PushAsync(new ContentPage { Title = "Pushed", Content = new Label { Text = "pushed page" } }, false);
    await Task.Delay(150);
    Console.WriteLine($"[verify] shell after push back={((OpenHarmonyView)shell.Handler!.PlatformView!).ShowsBack} title='{((OpenHarmonyView)shell.Handler!.PlatformView!).TitleText}'");
    var shellPlatform2 = (OpenHarmonyView)shell.Handler!.PlatformView!;
    shellPlatform2.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell after push back={shellPlatform2.ShowsBack} title='{shellPlatform2.TitleText}' backButtonHit={shellPlatform2.InBackButton(20, 20)}");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    await Task.Delay(250);
    shellPlatform2.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell after back tap back={shellPlatform2.ShowsBack} title='{shellPlatform2.TitleText}' stack={shellSection.Navigation.NavigationStack.Count}");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    Console.WriteLine($"[verify] shell after hamburger open={shellPlatform.FlyoutOpen}");
    rendererForShell.HandleTouch(shell, true, false, 60, 90);
    rendererForShell.HandleTouch(shell, false, true, 60, 90);
    Console.WriteLine($"[verify] shell after flyout item tap open={shellPlatform.FlyoutOpen} current='{shell.CurrentPage?.Title}'");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    rendererForShell.HandleTouch(shell, true, false, 900, 600);
    rendererForShell.HandleTouch(shell, false, true, 900, 600);
    Console.WriteLine($"[verify] shell after outside tap open={shellPlatform.FlyoutOpen}");
}

// W22-13: Essentials (Preferences + FileSystem).
Preferences.Set("verify.int", 42);
Preferences.Set("verify.text", "hello");
Preferences.Set("verify.flag", true);
Console.WriteLine($"[verify] preferences int={Preferences.Get("verify.int", 0)} text='{Preferences.Get("verify.text", "")}' flag={Preferences.Get("verify.flag", false)} contains={Preferences.ContainsKey("verify.text")}");
var preferencesInstance = app.Services.GetRequiredService<Microsoft.Maui.Storage.IPreferences>();
var reloaded = new OpenHarmonyPreferences(((OpenHarmonyPreferences)preferencesInstance).FilePath);
Console.WriteLine($"[verify] preferences reloaded int={reloaded.Get("verify.int", 0)} (persisted)");
Preferences.Remove("verify.int");
Console.WriteLine($"[verify] preferences after remove contains={Preferences.ContainsKey("verify.int")}");
string probeFile = Path.Combine(FileSystem.AppDataDirectory, "verify.txt");
File.WriteAllText(probeFile, "essentials");
Console.WriteLine($"[verify] filesystem dir='{FileSystem.AppDataDirectory}' cache='{FileSystem.CacheDirectory}' read='{File.ReadAllText(probeFile)}'");

// W22-13b: grid collection view.
var gridCtl = root.Children.OfType<CollectionView>().FirstOrDefault(c => c.ItemsLayout is GridItemsLayout);
if (gridCtl?.Handler?.PlatformView is OpenHarmonyView gridPlatform)
{
    var gridCells = gridPlatform.ViewChildren.OfType<View>().ToList();
    var frames = gridCells.Take(4).Select(v => v.Frame).ToList();
    Console.WriteLine($"[verify] grid cells={gridCells.Count} span=3 first4=[{string.Join(" ", frames.Select(f => $"{f.X:0},{f.Y:0},{f.Width:0}x{f.Height:0}"))}]");
}

// W22-14: SecureStorage / AppInfo / DeviceInfo / VersionTracking.
await SecureStorage.Default.SetAsync("verify.secret", "s3cr3t");
Console.WriteLine($"[verify] secure storage read='{await SecureStorage.Default.GetAsync("verify.secret")}'");
SecureStorage.Default.Remove("verify.secret");
Console.WriteLine($"[verify] secure storage after remove='{await SecureStorage.Default.GetAsync("verify.secret") ?? "<null>"}'");
Console.WriteLine($"[verify] appinfo package='{AppInfo.Current.PackageName}' version='{AppInfo.Current.VersionString}' device='{DeviceInfo.Current.Platform}/{DeviceInfo.Current.Idiom}'");
VersionTracking.Default.Track();
Console.WriteLine($"[verify] version tracking firstEver={VersionTracking.Default.IsFirstLaunchEver} previous='{VersionTracking.Default.PreviousVersion}' launches ok");

// Gap 1c assertions (swipe).
var swipeCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "swipe me");
if (swipeCtl is not null)
{
    Rect sf = swipeCtl.Frame;
    float sy = (float)(sf.Y + sf.Height / 2);
    host.HandleTouch(true, false, (float)(sf.X + sf.Width - 60), sy);
    host.HandleMove((float)(sf.X + 60), sy);
    host.HandleTouch(false, true, (float)(sf.X + 60), sy);
    Console.WriteLine($"[verify] swipe gesture direction={gestures.LastSwipe} (threshold 30, drag from x={sf.Right - 60:0} to {sf.X + 60:0})");
}

// Gap 1d: SwipeView reveals its right items on a left drag and activates them.
var swipeRow = root.Children.OfType<SwipeView>().FirstOrDefault();
if (swipeRow is not null)
{
    var swipePlatform = (OpenHarmonyView)swipeRow.Handler!.PlatformView!;
    RectF swipeFrame = swipeRow.Frame;
    Console.WriteLine($"[verify] swipeview items={swipePlatform.SwipeItems.Count} frame={swipeFrame} open={swipePlatform.IsSwipeOpen}");
    float swipeRowY = (float)(swipeFrame.Y + swipeFrame.Height / 2);
    host.HandleTouch(true, false, (float)(swipeFrame.Right - 40), swipeRowY);
    host.HandleMove((float)(swipeFrame.X + 40), swipeRowY);
    host.HandleTouch(false, true, (float)(swipeFrame.X + 40), swipeRowY);
    Console.WriteLine($"[verify] swipeview after drag open={swipePlatform.IsSwipeOpen} virtual={((ISwipeView)swipeRow).IsOpen}");
    RectF swipeItemRect = swipePlatform.SwipeItemRect(0);
    host.HandleTouch(true, false, swipeItemRect.Center.X, swipeItemRect.Center.Y);
    host.HandleTouch(false, true, swipeItemRect.Center.X, swipeItemRect.Center.Y);
    Console.WriteLine($"[verify] swipeview activated clicked={gestures.SwipeViewClicked} invoked={gestures.SwipeViewInvoked} open={swipePlatform.IsSwipeOpen}");
}

// Gap 1d: RefreshView pull triggers the refresh.
var refreshRow = root.Children.OfType<RefreshView>().FirstOrDefault();
if (refreshRow is not null)
{
    var refreshPlatform = (OpenHarmonyView)refreshRow.Handler!.PlatformView!;
    RectF refreshFrame = refreshRow.Frame;
    Console.WriteLine($"[verify] refreshview frame={refreshFrame} refreshing={refreshPlatform.IsRefreshing} runs={gestures.RefreshRuns}");
    float refreshX = (float)(refreshFrame.X + refreshFrame.Width / 2);
    host.HandleTouch(true, false, refreshX, (float)(refreshFrame.Y + 30));
    host.HandleMove(refreshX, (float)(refreshFrame.Y + 130));
    host.HandleTouch(false, true, refreshX, (float)(refreshFrame.Y + 130));
    Console.WriteLine($"[verify] refreshview after pull platform={refreshPlatform.IsRefreshing} virtual={refreshRow.IsRefreshing} runs={gestures.RefreshRuns}");
    refreshRow.IsRefreshing = false;
    host.Arrange(1080, 1920);
    Console.WriteLine($"[verify] refreshview after reset platform={refreshPlatform.IsRefreshing} virtual={refreshRow.IsRefreshing}");
}

// Gap 2: sensor kit wiring (device readings need real hardware).
try
{
    var accelerometer = Accelerometer.Default;
    Console.WriteLine($"[verify] sensors accel={accelerometer.GetType().Name} gyro={Gyroscope.Default.GetType().Name} supported={accelerometer.IsSupported}");
    accelerometer.ReadingChanged += (_, _) => { };
    Console.WriteLine($"[verify] sensors monitoring={accelerometer.IsMonitoring} after start attempt");
    accelerometer.Stop();
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] sensors default unavailable ({ex.GetType().Name})");
}

// Gap 2: the remaining Essentials sensor interfaces installed by the slice (desktop has no host
// library, so every IsSupported probe must answer false instead of throwing).
var magnetometerDefault = Magnetometer.Default;
var compassDefault = Compass.Default;
var barometerDefault = Barometer.Default;
var orientationDefault = OrientationSensor.Default;
Console.WriteLine($"[verify] sensors extra magnetometer={magnetometerDefault.GetType().Name} compass={compassDefault.GetType().Name} barometer={barometerDefault.GetType().Name} orientation={orientationDefault.GetType().Name} supported={magnetometerDefault.IsSupported}");

// Orientation is wired to SENSOR_TYPE_ROTATION_VECTOR (259): the host forwards four components
// (x, y, z, w) and the managed plumbing maps them onto OrientationSensorData unchanged, with no
// reconstructed scalar part. Off-device there is no host library, so invoke the managed callback
// the native listener calls; going through the public delegate type also pins the six-parameter
// native signature.
var orientationProbe = OpenHarmonyOrientationSensor.Instance;
Microsoft.Maui.Devices.Sensors.OrientationSensorData? rotationVectorReading = null;
void OnRotationVector(object? sender, Microsoft.Maui.Devices.Sensors.OrientationSensorChangedEventArgs e)
    => rotationVectorReading = e.Reading;
orientationProbe.ReadingChanged += OnRotationVector;
var onReadingMethod = typeof(OpenHarmonySensors).GetMethod("OnReading",
    System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
var sensorCallback = (OpenHarmonySensors.SensorCallback)Delegate.CreateDelegate(typeof(OpenHarmonySensors.SensorCallback), onReadingMethod);
sensorCallback(OpenHarmonySensors.OrientationType, 0.5f, -0.25f, 0.125f, 0.75f, 123456L);
orientationProbe.ReadingChanged -= OnRotationVector;
bool rotationVectorOk = OpenHarmonySensors.OrientationType == 259 && rotationVectorReading is not null &&
    rotationVectorReading.Value.Orientation.X == 0.5f && rotationVectorReading.Value.Orientation.Y == -0.25f &&
    rotationVectorReading.Value.Orientation.Z == 0.125f && rotationVectorReading.Value.Orientation.W == 0.75f;
Console.WriteLine($"[verify] sensors rotation vector type={OpenHarmonySensors.OrientationType} reading=({rotationVectorReading?.Orientation.X}, {rotationVectorReading?.Orientation.Y}, {rotationVectorReading?.Orientation.Z}, {rotationVectorReading?.Orientation.W}) unchanged={rotationVectorOk}");
if (!rotationVectorOk)
{
    throw new InvalidOperationException("the rotation-vector reading did not reach OrientationSensorData unchanged");
}

// Gap 2: haptic feedback over the host's NDK vibration export (ohos_host_vibrate ->
// OH_Vibrator_PlayVibration). Desktop builds have no libopenharmonyhost.so, so IsSupported
// must answer false and Perform(Click/LongPress) must degrade without throwing.
var hapticsDefault = HapticFeedback.Default;
Console.WriteLine($"[verify] haptics default is OpenHarmony={hapticsDefault is OpenHarmonyHapticFeedback} ({hapticsDefault.GetType().Name})");
bool hapticClickReturned = false;
bool hapticLongPressReturned = false;
try
{
    hapticsDefault.Perform(HapticFeedbackType.Click);
    hapticClickReturned = true;
    hapticsDefault.Perform(HapticFeedbackType.LongPress);
    hapticLongPressReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] haptics perform threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] haptics Perform(Click/LongPress) degraded without throwing={hapticClickReturned}/{hapticLongPressReturned}");
Console.WriteLine($"[verify] haptics IsSupported={hapticsDefault.IsSupported} static={HapticFeedback.IsSupported} (false without the host library)");

// Gap 2: app theme following over the ArkUI colour-mode bridge (Index.ets Environment.envProp
// 'colorMode' + @Watch -> host.notifyTheme -> ohos_host_theme_set_listener -> this handler).
// Desktop has no host library, so Register() must be a guarded no-op; the managed handler is
// then exercised directly (dark -> UserAppTheme/RequestedTheme Dark, light -> Light, restored).
bool themeRegisterReturned = false;
try
{
    OpenHarmonyTheme.Register();
    themeRegisterReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] theme register threw {ex.GetType().Name}: {ex.Message}");
}
var themeBefore = Application.Current!.UserAppTheme;
OpenHarmonyTheme.OnPlatformThemeChanged(true);
bool themeDark = Application.Current.UserAppTheme == AppTheme.Dark && Application.Current.RequestedTheme == AppTheme.Dark;
OpenHarmonyTheme.OnPlatformThemeChanged(false);
bool themeLight = Application.Current.UserAppTheme == AppTheme.Light && Application.Current.RequestedTheme == AppTheme.Light;
Application.Current.UserAppTheme = themeBefore;
Console.WriteLine($"[verify] theme register degraded without throwing={themeRegisterReturned} (no host library)");
Console.WriteLine($"[verify] theme bridge dark={themeDark} light={themeLight} restored={Application.Current.UserAppTheme == themeBefore} last={OpenHarmonyTheme.LastIsDark}");

// Gap 2: notification kit (the shell publishes on device; desktop degrades to false).
Console.WriteLine($"[verify] notifications show(on desktop)={OpenHarmonyNotifications.Show("Title", "Text")}");

// Gap 2: TextToSpeech over the Speech Kit bridge (the OpenHarmony SDK ships no speech module,
// so the shell sink answers unavailable and the managed side must degrade without throwing).
var ttsDefault = Microsoft.Maui.Media.TextToSpeech.Default;
Console.WriteLine($"[verify] tts default is OpenHarmony={ttsDefault is OpenHarmonyTextToSpeech} ({ttsDefault.GetType().Name})");
bool ttsSpeakReturned = false;
try
{
    await ttsDefault.SpeakAsync("verify speech");
    ttsSpeakReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] tts speak threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] tts speak degraded without throwing={ttsSpeakReturned}");
var ttsLocales = (await ttsDefault.GetLocalesAsync()).ToList();
Console.WriteLine($"[verify] tts locales={ttsLocales.Count} first='{ttsLocales.FirstOrDefault()?.Id}' language='{ttsLocales.FirstOrDefault()?.Language}'");

// Gap 3: camera capture goes through the shell picker (device only).
Console.WriteLine($"[verify] media captureSupported={MediaPicker.Default.IsCaptureSupported} capture={await MediaPicker.Default.CapturePhotoAsync() is null} (null off-device)");

// Limitations re-audit: pointer gestures.
var pointerCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "hover me");
if (pointerCtl is not null)
{
    host.Arrange(1080, 1920);
    Rect pf = pointerCtl.Frame;
    float px = (float)(pf.X + pf.Width / 2);
    float py = (float)(pf.Y + pf.Height / 2);
    host.HandleTouch(true, false, px, py);
    host.HandleTouch(false, true, px, py);
    Console.WriteLine($"[verify] pointer entered={gestures.PointerEntered} pressed={gestures.PointerPressed} released={gestures.PointerReleased} exited={gestures.PointerExited}");
    // pointer move test (mouse hover arrives as a touch move)
    gestures.PointerEntered = gestures.PointerExited = false;
    host.HandleMove(px, py);
    bool movedIn = gestures.PointerEntered;
    host.HandleMove(10f, 1500f);
    Console.WriteLine($"[verify] pointer hover entered={movedIn} exited={gestures.PointerExited}");
}

// Limitations re-audit: pinch gestures (managed half, public IPinchGestureController).
var pinchCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pinch me");
if (pinchCtl is not null)
{
    host.Arrange(1080, 1920);
    Rect kf = pinchCtl.Frame;
    float kx = (float)(kf.X + kf.Width / 2);
    float ky = (float)(kf.Y + kf.Height / 2);
    OpenHarmonyPinch.Dispatch(pinchCtl, 0, 1.0, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 1, 1.5, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 1, 2.0, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 2, 1.0, kx, ky);
    Console.WriteLine($"[verify] pinch events={gestures.PinchLog.Trim()}");
}

// Batch D1: visual diagnostics overlay.
OpenHarmonyDiagnostics.Enabled = true;
host.Arrange(1080, 1920);
host.Render();
Console.WriteLine($"[verify] diagnostics outlines={OpenHarmonyDiagnostics.OutlinesDrawn} enabled={OpenHarmonyDiagnostics.Enabled}");
OpenHarmonyDiagnostics.Enabled = false;
Console.WriteLine($"[verify] a11y nodes={OpenHarmonyAccessibility.Nodes.Count} buttons={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "button")} texts={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "text")}");
var a11ySample = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Text == "hover me");
Console.WriteLine($"[verify] a11y sample text='{a11ySample?.Text}' role={a11ySample?.Role} focusable={a11ySample?.IsFocusable} bounds={a11ySample?.Bounds.Width:0}x{a11ySample?.Bounds.Height:0}");
Console.WriteLine($"[verify] a11y publish off-device={OpenHarmonyAccessibility.LastPublishedCount} (no throw)");
Console.WriteLine($"[verify] a11y heading role={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "header")} hints={OpenHarmonyAccessibility.Nodes.Count(n => !string.IsNullOrEmpty(n.Hint))}");
// Change a label's text and re-render: the diff should report a text update.
var a11yTextCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "hover me");
if (a11yTextCtl is not null)
{
    a11yTextCtl.Text = "hover me v2";
    host.Render();
    Console.WriteLine($"[verify] a11y events after text change={OpenHarmonyAccessibility.PendingEventCount} (text update bit={(OpenHarmonyAccessibility.PendingEventCount & 0x10) != 0})");
}

// D2: accessibility action routing (CLICK -> normal tap path).
var a11yTapNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Text == "tap me" && n.Role == "text");
if (a11yTapNode is not null)
{
    int tapsBefore = gestures.TapCount;
    bool clickHandled = host.HandleAccessibilityAction(a11yTapNode.Id, 0x10);
    Console.WriteLine($"[verify] a11y click handled={clickHandled} taps {tapsBefore}->{gestures.TapCount}");
}

// Audit: an unchanged frame must not re-publish the tree to the host.
if (OpenHarmonyAccessibility.Nodes.Count > 0)
{
    host.Render();
    int skippedBefore = OpenHarmonyAccessibility.FramesSkipped;
    host.Render();
    Console.WriteLine($"[verify] a11y skip unchanged frame: wouldPublish={OpenHarmonyAccessibility.WouldPublish} skipped {skippedBefore}->{OpenHarmonyAccessibility.FramesSkipped}");
}
Console.WriteLine($"[verify] a11y actions text=[{string.Join(",", OpenHarmonyAccessibility.ActionsFor("text"))}] input=[{string.Join(",", OpenHarmonyAccessibility.ActionsFor("textInput"))}]");

// Alert overlay: DisplayAlert shows in the compositor and a button tap completes it.
var alertTask = page.DisplayAlert("Alert title", "Alert message", "OK", "Cancel");
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] alert shown={OpenHarmonyAlertHost.IsVisible} pending={!alertTask.IsCompleted}");
var acceptRect = OpenHarmonyAlertHost.AcceptRect;
bool alertDown = host.HandleTouch(true, false, acceptRect.Center.X, acceptRect.Center.Y);
bool alertUp = host.HandleTouch(false, true, acceptRect.Center.X, acceptRect.Center.Y);
Console.WriteLine($"[verify] alert tap handled={alertDown}/{alertUp} visible={OpenHarmonyAlertHost.IsVisible} result={(alertTask.IsCompleted ? (await alertTask).ToString() : "pending")}");

// Action sheet overlay: options resolve the sheet.
var sheetTask = page.DisplayActionSheet("Pick one", "Cancel", null, "Alpha", "Beta");
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] sheet options={OpenHarmonyAlertHost.Current?.Options.Count} title='{OpenHarmonyAlertHost.Current?.Title}'");
var rowRect = OpenHarmonyAlertHost.OptionRect(1);
host.HandleTouch(true, false, rowRect.Center.X, rowRect.Center.Y);
host.HandleTouch(false, true, rowRect.Center.X, rowRect.Center.Y);
Console.WriteLine($"[verify] sheet result={(sheetTask.IsCompleted ? await sheetTask : "pending")} visible={OpenHarmonyAlertHost.IsVisible}");

// Prompt overlay: keyboard text edits it and Accept resolves the string.
var promptTask = page.DisplayPromptAsync("Name", "Type it");
host.Arrange(1080, 1920);
OpenHarmonyAlertHost.PromptAppend("hello");
OpenHarmonyAlertHost.PromptAppend("!");
Console.WriteLine($"[verify] prompt text='{OpenHarmonyAlertHost.Current?.PromptText}' pending={!promptTask.IsCompleted}");
var promptAccept = OpenHarmonyAlertHost.AcceptRect;
host.HandleTouch(true, false, promptAccept.Center.X, promptAccept.Center.Y);
host.HandleTouch(false, true, promptAccept.Center.X, promptAccept.Center.Y);
Console.WriteLine($"[verify] prompt result={(promptTask.IsCompleted ? (await promptTask) ?? "<null>" : "pending")}");

// Audit batch 2 assertions.
var graphicsCtl = root.Children.OfType<GraphicsView>().FirstOrDefault();
if (graphicsCtl?.Handler?.PlatformView is OpenHarmonyView graphicsPlatform)
{
    var rendererForGraphics = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
    rendererForGraphics.Render(navRoot, 1080, 1920);
    Console.WriteLine($"[verify] graphicsview drawCalled={gestures.Drawable?.DrawCalls} frame={graphicsCtl.Frame}");
    Rect gf = graphicsCtl.Frame;
    host.HandleTouch(true, false, (float)(gf.X + 10), (float)(gf.Y + 10));
    host.HandleTouch(false, true, (float)(gf.X + 10), (float)(gf.Y + 10));
    Console.WriteLine($"[verify] graphicsview touchCalls={gestures.Drawable?.TouchCalls}");
}
var contentViewCtl = root.Children.OfType<ContentView>().FirstOrDefault();
if (contentViewCtl is not null)
{
    var inner = contentViewCtl.Content as Label;
    Console.WriteLine($"[verify] contentview frame={contentViewCtl.Frame} inner={inner?.Frame} text='{inner?.Text}'");
}
var imageButtonCtl = root.Children.OfType<ImageButton>().FirstOrDefault();
if (imageButtonCtl?.Handler?.PlatformView is OpenHarmonyView imageButtonPlatform)
{
    Console.WriteLine($"[verify] imagebutton bytes={imageButtonPlatform.ImageBytes?.Length ?? 0}");
}

// Modal pages: pushed modals take over rendering.
var controlsWindow = (Microsoft.Maui.Controls.Window)host.Window!;
await controlsWindow.Navigation.PushModalAsync(new ContentPage { Title = "Modal", Content = new Label { Text = "modal page" } }, false);
await Task.Delay(100);
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] modal describe root: {(host.Describe().Split('\n').FirstOrDefault() ?? "").Trim()}");
await controlsWindow.Navigation.PopModalAsync(false);
await Task.Delay(100);
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] after pop root: {(host.Describe().Split('\n').FirstOrDefault() ?? "").Trim()}");

// Audit batch assertions.
var boxCtl = root.Children.OfType<BoxView>().FirstOrDefault();
if (boxCtl?.Handler?.PlatformView is OpenHarmonyView boxPlatform)
{
    Console.WriteLine($"[verify] boxview frame={boxCtl.Frame} background={(boxPlatform.Background is not null)}");
}
var indicatorCtl = root.Children.OfType<IndicatorView>().FirstOrDefault();
if (indicatorCtl?.Handler?.PlatformView is OpenHarmonyView indicatorPlatform)
{
    Console.WriteLine($"[verify] indicator count={indicatorPlatform.IndicatorCount} position={indicatorPlatform.IndicatorPosition}");
}
var frameCtl = root.Children.OfType<Frame>().FirstOrDefault();
if (frameCtl is not null)
{
    var innerLabel = frameCtl.Content as Label;
    Console.WriteLine($"[verify] frame frame={frameCtl.Frame} inner={innerLabel?.Frame} text='{innerLabel?.Text}'");
}
var editorCtl = root.Children.OfType<Editor>().FirstOrDefault();
if (editorCtl is not null)
{
    Rect ef2 = editorCtl.Frame;
    host.HandleTouch(true, false, (float)(ef2.X + 20), (float)(ef2.Y + 20));
    host.HandleTouch(false, true, (float)(ef2.X + 20), (float)(ef2.Y + 20));
    editorCtl.Text = "editor text";
    var editorPlatform = (OpenHarmonyView)editorCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] editor focused={editorPlatform.IsFocused} text='{editorPlatform.Text}'");
}
var xamlPage = new verify.XamlPage();
OpenHarmonyHandlerConnector.ConnectTree(xamlPage);
xamlPage.Measure(1080, 600);
xamlPage.Arrange(new Rect(0, 0, 1080, 600));
Console.WriteLine($"[verify] xaml page label='{xamlPage.FindByName<Label>("XamlTitle")?.Text}' button='{xamlPage.FindByName<Button>("XamlButton")?.Text}' frame={xamlPage.FindByName<Label>("XamlTitle")?.Frame}");

// W22-15: grouped collection + carousel loop.
var groupedCtl = root.Children.OfType<CollectionView>().FirstOrDefault(c => c.IsGrouped);
if (groupedCtl?.Handler?.PlatformView is OpenHarmonyView groupedPlatform)
{
    var rows = groupedPlatform.ViewChildren.OfType<View>()
        .Select(v => (v.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "?")
        .ToList();
    Console.WriteLine($"[verify] grouped rows={rows.Count} [{string.Join(", ", rows.Take(6))}] content={groupedPlatform.ScrollContentHeight:0}");
}

var loopCtl = root.Children.OfType<CarouselView>().FirstOrDefault();
if (loopCtl?.Handler?.PlatformView is OpenHarmonyView loopPlatform)
{
    loopCtl.Position = 2;
    loopCtl.Handler!.UpdateValue("Position");
    Rect lf2 = loopCtl.Frame;
    float ly = (float)(lf2.Y + lf2.Height / 2);
    rendererForShell.HandleTouch(navRoot, true, false, (float)(lf2.X + lf2.Width - 40), ly);
    rendererForShell.HandleMove((float)(lf2.X + lf2.Width - 220), ly);
    rendererForShell.HandleTouch(navRoot, false, true, (float)(lf2.X + lf2.Width - 220), ly);
    string currentItem = (loopPlatform.ViewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "<none>";
    Console.WriteLine($"[verify] carousel loop position={loopCtl.Position} item='{currentItem}' (wrapped from 2)");
}

// W22-17: clipboard / connectivity / launcher / browser / share.
await Clipboard.Default.SetTextAsync("clip-text");
Console.WriteLine($"[verify] clipboard hasText={Clipboard.Default.HasText} text='{await Clipboard.Default.GetTextAsync()}'");
await Clipboard.Default.SetTextAsync(null);
Console.WriteLine($"[verify] clipboard after clear hasText={Clipboard.Default.HasText}");
Console.WriteLine($"[verify] connectivity access={Connectivity.Current.NetworkAccess} profiles={Connectivity.Current.ConnectionProfiles.Count()}");
Console.WriteLine($"[verify] launcher open={await Launcher.Default.TryOpenAsync(new Uri("https://example.com"))} browser open={await Browser.Default.OpenAsync(new Uri("https://example.com"))}");
await Share.Default.RequestAsync(new ShareTextRequest { Text = "hello" });
Console.WriteLine("[verify] share request completed (no host library -> degraded, documented)");

// Gap 4: app-launching essentials (Launcher/Browser/Share) over the ArkTS ability bridge
// (ohos_host_ability_start -> shell registerAbilitySink -> UIAbilityContext.startAbility).
// On desktop there is no libopenharmonyhost.so, so every call must degrade to false without
// throwing, and the three Essentials defaults must be this slice's implementations.
var launcherDefault = Launcher.Default;
var browserDefault = Browser.Default;
var shareDefault = Share.Default;
Console.WriteLine($"[verify] intents defaults launcher={launcherDefault.GetType().Name} browser={browserDefault.GetType().Name} share={shareDefault.GetType().Name}");
Console.WriteLine($"[verify] intents defaults are OpenHarmony={launcherDefault is OpenHarmonyLauncher} browser={browserDefault is OpenHarmonyBrowser} share={shareDefault is OpenHarmonyShare}");
bool canOpen = false;
bool launcherOpen = false;
bool launcherTryOpen = false;
try
{
    canOpen = await launcherDefault.CanOpenAsync(new Uri("https://example.com"));
    launcherOpen = await launcherDefault.OpenAsync(new Uri("https://example.com"));
    launcherTryOpen = await launcherDefault.TryOpenAsync(new Uri("https://example.com"));
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents launcher threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents launcher degraded without throwing canOpen={canOpen} open={launcherOpen} tryOpen={launcherTryOpen}");
bool browserOpen = false;
try
{
    browserOpen = await browserDefault.OpenAsync(new Uri("https://example.com"), BrowserLaunchMode.SystemPreferred);
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents browser threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents browser degraded without throwing={browserOpen}");
bool openFile = false;
try
{
    openFile = await launcherDefault.OpenAsync(new OpenFileRequest { File = new ReadOnlyFile(imagePath) });
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents launcher file threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents launcher file request degraded without throwing open={openFile}");
bool shareTextReturned = false;
bool shareFileReturned = false;
try
{
    await shareDefault.RequestAsync(new ShareTextRequest { Text = "verify share" });
    shareTextReturned = true;
    await shareDefault.RequestAsync(new ShareFileRequest { File = new ShareFile(imagePath) });
    shareFileReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents share threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents share degraded without throwing text={shareTextReturned} file={shareFileReturned}");

// W22-12: ListView (virtualized cells) + CarouselView swipe.
var listCtl = root.Children.OfType<ListView>().FirstOrDefault();
if (listCtl?.Handler?.PlatformView is OpenHarmonyView listPlatform)
{
    var cells = listPlatform.ViewChildren.OfType<View>().ToList();
    var firstCell = cells.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] listview materialized={cells.Count} of 12 first='{firstCell?.Text}' content={listPlatform.ScrollContentHeight:0}");
    Rect lf = listCtl.Frame;
    float lx = (float)(lf.X + lf.Width / 2);
    rendererForShell.HandleTouch(navRoot, true, false, lx, (float)(lf.Y + lf.Height - 30));
    rendererForShell.HandleMove(lx, (float)(lf.Y + 30));
    rendererForShell.HandleTouch(navRoot, false, true, lx, (float)(lf.Y + 30));
    var after = listPlatform.ViewChildren.OfType<View>().ToList();
    Console.WriteLine($"[verify] listview after drag offset={listPlatform.ScrollOffsetY:0} materialized={after.Count}");
}

var carouselCtl = root.Children.OfType<CarouselView>().FirstOrDefault();
if (carouselCtl?.Handler?.PlatformView is OpenHarmonyView carouselPlatform)
{
    string Current() => (carouselPlatform.ViewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "<none>";
    Console.WriteLine($"[verify] carousel position={carouselCtl.Position} item='{Current()}'");
    Rect cf2 = carouselCtl.Frame;
    float cy2 = (float)(cf2.Y + cf2.Height / 2);
    rendererForShell.HandleTouch(navRoot, true, false, (float)(cf2.X + cf2.Width - 40), cy2);
    rendererForShell.HandleMove((float)(cf2.X + cf2.Width - 200), cy2);
    rendererForShell.HandleTouch(navRoot, false, true, (float)(cf2.X + cf2.Width - 200), cy2);
    Console.WriteLine($"[verify] carousel after swipe position={carouselCtl.Position} item='{Current()}'");
}

// W22-9: flyout page.
var rendererForFlyout = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var flyoutFlyout = new ContentPage { Title = "menu", Content = new Label { Text = "flyout content" } };
var flyoutDetail = new ContentPage { Title = "detail", Content = new Label { Text = "detail content" } };
var flyoutPage = new FlyoutPage { Flyout = flyoutFlyout, Detail = flyoutDetail, IsPresented = false };
OpenHarmonyHandlerConnector.ConnectTree(flyoutPage);
flyoutPage.Measure(1080, 1920);
flyoutPage.Arrange(new Rect(0, 0, 1080, 1920));
if (flyoutPage.Handler?.PlatformView is OpenHarmonyView flyoutPlatform)
{
    Console.WriteLine($"[verify] flyout initial presented={flyoutPlatform.FlyoutPresented} width={flyoutPlatform.FlyoutWidth:0} detailLabel={((View)flyoutDetail.Content!).Frame}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 20, 20);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 20, 20);
    Console.WriteLine($"[verify] flyout after hamburger presented={flyoutPage.IsPresented} flyoutLabel={((View)flyoutFlyout.Content!).Frame}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 100, 400);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 100, 400);
    Console.WriteLine($"[verify] flyout after panel tap presented={flyoutPage.IsPresented}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 800, 400);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 800, 400);
    Console.WriteLine($"[verify] flyout after outside tap presented={flyoutPage.IsPresented}");
}

// W22-7b: tabbed page.
Console.WriteLine($"[verify] Application.Current={Application.Current?.GetType().Name ?? "null"} dispatcher={Application.Current?.Dispatcher?.GetType().Name ?? "null"}");
var tabOne = new ContentPage { Title = "One", Content = new Label { Text = "tab one" } };
var tabTwo = new ContentPage { Title = "Two", Content = new Label { Text = "tab two" } };
var tabbed = new TabbedPage { Children = { tabOne, tabTwo } };
OpenHarmonyHandlerConnector.ConnectTree(tabbed);
tabbed.Measure(1080, 1920);
tabbed.Arrange(new Rect(0, 0, 1080, 1920));
var renderer = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
if (tabbed.Handler?.PlatformView is OpenHarmonyView tabPlatform)
{
    Console.WriteLine($"[verify] tabbed titles=[{string.Join(",", tabPlatform.TabTitles)}] selected={tabPlatform.SelectedTab} current='{tabbed.CurrentPage?.Title}'");
    double tabY = tabbed.Frame.Height - OpenHarmonyView.TabBarHeight / 2;
    double tabX = tabbed.Frame.Width * 0.75;
    renderer.HandleTouch(tabbed, true, false, (float)tabX, (float)tabY);
    renderer.HandleTouch(tabbed, false, true, (float)tabX, (float)tabY);
    Console.WriteLine($"[verify] tabbed after tap selected={tabPlatform.SelectedTab} current='{tabbed.CurrentPage?.Title}'");
    var contentFrame = ((View)tabTwo.Content!).Frame;
    Console.WriteLine($"[verify] tabbed content frame={contentFrame} (page arranged above the bar)");
}

// W22-6: gestures, selection, transforms.
var tapCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "tap me");
if (tapCtl is not null)
{
    Rect f = tapCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] tap gesture count={gestures.TapCount}");
}

var panCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pan me");
if (panCtl is not null)
{
    Rect f = panCtl.Frame;
    float x = (float)(f.X + 20);
    host.HandleTouch(true, false, x, (float)(f.Y + 4));
    host.HandleMove(x, (float)(f.Y + 30));
    host.HandleMove(x, (float)(f.Y + 54));
    host.HandleTouch(false, true, x, (float)(f.Y + 54));
    Console.WriteLine($"[verify] pan gesture started={gestures.PanStarted} totalY={gestures.PanTotalY:0.#} completed={gestures.PanCompleted}");
}

// Gap 1e: drag-and-drop gestures (long press + move, drop target hit testing). The recognizers
// are attached to labels already arranged near the top of the page so this check does not shift
// the frames the rest of the suite asserts.
var dragSourceCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "swipe me");
var dropTargetCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pinch me");
if (dragSourceCtl is not null && dropTargetCtl is not null)
{
    var dragRecognizer = new Microsoft.Maui.Controls.DragGestureRecognizer();
    dragRecognizer.DragStarting += (_, _) => gestures.DragStartingCount++;
    dragRecognizer.DropCompleted += (_, e) =>
    {
        gestures.DropCompletedCount++;
        gestures.LastDropResult = gestures.DropResultOf(e);
    };
    dragSourceCtl.GestureRecognizers.Add(dragRecognizer);

    var dropRecognizer = new Microsoft.Maui.Controls.DropGestureRecognizer();
    dropRecognizer.DragOver += (_, e) =>
    {
        gestures.DragOverCount++;
        gestures.LastDragOverText = e.Data.Text;
    };
    dropRecognizer.DragLeave += (_, _) => gestures.DragLeaveCount++;
    dropRecognizer.Drop += (_, e) =>
    {
        gestures.DropCount++;
        gestures.DroppedText = e.Data.GetTextAsync().GetAwaiter().GetResult();
    };
    dropTargetCtl.GestureRecognizers.Add(dropRecognizer);

    host.Arrange(1080, 1920);
    Rect sourceFrame = dragSourceCtl.Frame;
    Rect targetFrame = dropTargetCtl.Frame;
    float sx = (float)(sourceFrame.X + sourceFrame.Width / 2);
    float sy = (float)(sourceFrame.Y + sourceFrame.Height / 2);
    float tx = (float)(targetFrame.X + targetFrame.Width / 2);
    float ty = (float)(targetFrame.Y + targetFrame.Height / 2);

    // (1) Long press + move starts the drag; entering the target raises DragOver, leaving and
    //     re-entering raises DragLeave/DragOver, and releasing over it delivers Drop with the
    //     source text, then DropCompleted on the source.
    gestures.DragStartingCount = gestures.DragOverCount = gestures.DragLeaveCount = 0;
    gestures.DropCount = gestures.DropCompletedCount = 0;
    gestures.LastDragOverText = gestures.DroppedText = null;
    bool dd = host.HandleTouch(true, false, sx, sy);
    await Task.Delay(600);
    bool dm = host.HandleMove(sx + 24, sy);
    bool dOver = host.HandleMove(tx, ty);
    bool dAway = host.HandleMove(sx, 1900f);
    bool dBack = host.HandleMove(tx, ty);
    bool du = host.HandleTouch(false, true, tx, ty);
    bool dropFlowOk = gestures.DragStartingCount == 1 && gestures.DragOverCount == 2 &&
                      gestures.DragLeaveCount == 1 && gestures.LastDragOverText == "swipe me" &&
                      gestures.DropCount == 1 && gestures.DroppedText == "swipe me" &&
                      gestures.DropCompletedCount == 1;
    Console.WriteLine($"[verify] drag/drop handled={dd}/{dm}/{dOver}/{dAway}/{dBack}/{du} starting={gestures.DragStartingCount} over={gestures.DragOverCount} leave={gestures.DragLeaveCount} drop={gestures.DropCount} text='{gestures.DroppedText}' completed={gestures.DropCompletedCount} assert={dropFlowOk}");
    if (!dropFlowOk)
    {
        throw new InvalidOperationException("drag/drop flow assertion failed");
    }

    // (2) Releasing over nothing raises no Drop and DropCompleted reports no operation (failure).
    gestures.DragStartingCount = gestures.DragOverCount = gestures.DragLeaveCount = 0;
    gestures.DropCount = gestures.DropCompletedCount = 0;
    gestures.DroppedText = null;
    float emptyY = 1900f;
    host.HandleTouch(true, false, sx, sy);
    await Task.Delay(600);
    host.HandleMove(sx + 24, sy);
    host.HandleMove(sx, emptyY);
    host.HandleTouch(false, true, sx, emptyY);
    bool noTargetOk = gestures.DragStartingCount == 1 && gestures.DragOverCount == 0 &&
                      gestures.DropCount == 0 && gestures.DropCompletedCount == 1 &&
                      gestures.LastDropResult == "None";
    Console.WriteLine($"[verify] drag/drop over nothing starting={gestures.DragStartingCount} over={gestures.DragOverCount} drop={gestures.DropCount} completed={gestures.DropCompletedCount} result={gestures.LastDropResult} success=false={noTargetOk}");
    if (!noTargetOk)
    {
        throw new InvalidOperationException("drag/drop over nothing assertion failed");
    }

    // (3) Moving beyond the slop before the long-press window never promotes the press.
    gestures.DragStartingCount = 0;
    host.HandleTouch(true, false, sx, sy);
    host.HandleMove(sx, sy + 24);
    host.HandleMove(sx, sy + 48);
    host.HandleTouch(false, true, sx, sy + 48);
    Console.WriteLine($"[verify] drag/drop early move starting={gestures.DragStartingCount} (no drag before 500 ms) assert={gestures.DragStartingCount == 0}");
    if (gestures.DragStartingCount != 0)
    {
        throw new InvalidOperationException("early-move drag assertion failed");
    }
}

var animatedCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "transformed");
if (animatedCtl is not null)
{
    Console.WriteLine("[verify] transform: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("transform=")) ?? "<none>").Trim());
}

// W22-5: shapes/border/stepper/radio/search bar.
var shapesRow = root.Children.OfType<HorizontalStackLayout>().FirstOrDefault(l => l.Children.OfType<View>().Any(v => v.GetType().Name == "Rectangle"));
if (shapesRow is not null)
{
    foreach (var shapeView in shapesRow.Children.OfType<View>())
    {
        var platform = shapeView.Handler?.PlatformView as OpenHarmonyView;
        var path = platform?.Shape?.PathForBounds(new Microsoft.Maui.Graphics.RectF(platform.Frame.X, platform.Frame.Y, platform.Frame.Width, platform.Frame.Height));
        string fill = platform?.ShapeFill is Microsoft.Maui.Graphics.SolidPaint sp ? sp.Color.ToHex() : "null";
        Console.WriteLine($"[verify] shape {shapeView.GetType().Name} frame={shapeView.Frame} pathPoints={(path?.Points?.Count() ?? 0)} fill={fill}");
    }
}

var borderCtl = root.Children.OfType<Border>().FirstOrDefault();
if (borderCtl is not null)
{
    var innerLabel = (borderCtl.Content as Label);
    Console.WriteLine($"[verify] border frame={borderCtl.Frame} inner={innerLabel?.Frame} text='{innerLabel?.Text}'");
}

var stepperCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Stepper>().FirstOrDefault();
if (stepperCtl is not null)
{
    Rect f = stepperCtl.Frame;
    float y = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.25), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.25), y);
    Console.WriteLine($"[verify] stepper after +/+/- value={stepperCtl.Value} (virtual)");
}

var radioCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<RadioButton>().FirstOrDefault();
if (radioCtl is not null)
{
    Rect f = radioCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] radio after tap checked={radioCtl.IsChecked}");
}

var searchCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<SearchBar>().FirstOrDefault();
if (searchCtl is not null)
{
    searchCtl.Text = "hello search";
    var platform = (OpenHarmonyView)searchCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] searchbar text='{platform.Text}' placeholder='{platform.Placeholder}'");
}

// W22-4: collection view items + drag scrolling.
var collectionCtl = root.Children.OfType<CollectionView>()
    .FirstOrDefault(c => !c.IsGrouped && c.ItemsLayout is not GridItemsLayout);
if (collectionCtl is not null && collectionCtl.Handler?.PlatformView is OpenHarmonyView collectionPlatform)
{
    var viewChildren = collectionPlatform.ViewChildren.OfType<View>().ToList();
    var firstLabel = viewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    var lastLabel = viewChildren.LastOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection materialized={viewChildren.Count} of 20 first='{firstLabel?.Text}' last='{lastLabel?.Text}' content={collectionPlatform.ScrollContentHeight:0}");
    collectionCtl.SelectionChanged += (_, e) => Console.WriteLine($"[verify] collection SelectionChanged='{e.CurrentSelection.FirstOrDefault()}'");
    var itemViews = collectionPlatform.ViewChildren.OfType<View>().ToList();
    if (itemViews.Count > 2)
    {
        Rect itemFrame = itemViews[2].Frame;
        host.HandleTouch(true, false, (float)(itemFrame.X + 20), (float)(itemFrame.Y + 10));
        host.HandleTouch(false, true, (float)(itemFrame.X + 20), (float)(itemFrame.Y + 10));
        var selectedItemView = itemViews[2].Handler?.PlatformView as OpenHarmonyView;
    var unselectedItemView = itemViews[0].Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection tap selected='{collectionCtl.SelectedItem}' highlight={(selectedItemView?.Background is not null)} otherHighlight={(unselectedItemView?.Background is not null)} (itemFrame={itemFrame})");
    }

    Rect cf = collectionCtl.Frame;
    float cx = (float)(cf.X + cf.Width / 2);
    bool cd = host.HandleTouch(true, false, cx, (float)(cf.Y + cf.Height - 40));
    bool cm = host.HandleMove(cx, (float)(cf.Y + 40));
    host.HandleTouch(false, true, cx, (float)(cf.Y + 40));
    var afterDrag = collectionPlatform.ViewChildren.OfType<View>().ToList();
    var afterFirst = afterDrag.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection drag handled={cd}/{cm} offset={collectionPlatform.ScrollOffsetY:0} materialized={afterDrag.Count} first='{afterFirst?.Text}'");
}

// W22-3: navigation page (bar + push/pop).
var navigation = navRoot;
Console.WriteLine("[verify] nav initial: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("nav=")) ?? "<none>").Trim());

var pageTwo = new ContentPage
{
    Title = "Page Two",
    Content = new VerticalStackLayout { Padding = 24, Children = { new Label { Text = "second page", FontSize = 32 } } },
};
try
{
    var pushTask = navigation.PushAsync(pageTwo, false);
    if (await Task.WhenAny(pushTask, Task.Delay(3000)) != pushTask)
    {
        Console.WriteLine("[verify] PushAsync did not complete within 3s");
    }
    else
    {
        Console.WriteLine("[verify] PushAsync completed");
    }
    host.Arrange(1080, 1920);
    Console.WriteLine("[verify] after push: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("nav=")) ?? "<none>").Trim());
    Console.WriteLine("[verify] stack=" + string.Join("/", navigation.Navigation.NavigationStack.Select(p => p.Title)));
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] PushAsync threw {ex.GetType().Name}: {ex.Message}");
}

Rect navFrame = navigation.Frame;
var navPlatform = (OpenHarmonyView)navigation.Handler!.PlatformView!;
bool downHandled = host.HandleTouch(true, false, (float)(navFrame.X + 20), (float)(navFrame.Y + 20));
Console.WriteLine($"[verify] nav down handled={downHandled} canGoBack={navPlatform.CanGoBack} inBack={navPlatform.InBackRegion(20, 20)} pressed={navPlatform.Pressed}");
bool back = host.HandleTouch(false, true, (float)(navFrame.X + 20), (float)(navFrame.Y + 20));

host.Arrange(1080, 1920);
Console.WriteLine($"[verify] back tap handled={back} stack={string.Join("/", navigation.Navigation.NavigationStack.Select(p => p.Title))}");

// Gap 1d: toolbar items draw in the navigation bar and activate on tap.
int toolbarClicks = 0;
var toolbarPage = navRoot.CurrentPage;
toolbarPage.ToolbarItems.Add(new ToolbarItem { Text = "Sync", Command = new Command(() => toolbarClicks++) });
host.Arrange(1080, 1920);
var toolbarNav = (OpenHarmonyView)navRoot.Handler!.PlatformView!;
RectF syncRect = toolbarNav.ToolbarItemRect(0);
Console.WriteLine($"[verify] toolbar items={toolbarNav.ToolbarItems.Count} rect={syncRect}");
host.HandleTouch(true, false, syncRect.Center.X, syncRect.Center.Y);
host.HandleTouch(false, true, syncRect.Center.X, syncRect.Center.Y);
Console.WriteLine($"[verify] toolbar clicks={toolbarClicks} pressed={toolbarNav.Pressed}");

// Value controls: tap the check box / switch, drag the slider.
void TapView(View view)
{
    Rect f = view.Frame;
    float cx = (float)(f.X + f.Width / 2);
    float cy = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, cx, cy);
    host.HandleTouch(false, true, cx, cy);
}

var checkBoxCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<CheckBox>().FirstOrDefault();
if (checkBoxCtl is not null)
{
    TapView(checkBoxCtl);
    var platform = (OpenHarmonyView)checkBoxCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] checkbox after tap checked={platform.IsChecked} (virtual={checkBoxCtl.IsChecked})");
}

var switchCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Switch>().FirstOrDefault();
if (switchCtl is not null)
{
    TapView(switchCtl);
    var platform = (OpenHarmonyView)switchCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] switch after tap on={platform.IsOn} (virtual={switchCtl.IsToggled})");
}

var sliderCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Slider>().FirstOrDefault();
if (sliderCtl is not null)
{
    Rect f = sliderCtl.Frame;
    float y = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, (float)(f.X + 10), y);
    Console.WriteLine($"[verify] slider move x={(float)(f.X + f.Width - 10):0} range=({f.X + 10:0},{f.X + f.Width - 10:0})");
    bool m = host.HandleMove((float)(f.X + f.Width - 10), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width - 10), y);
    var platform = (OpenHarmonyView)sliderCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] slider frame={f} fraction={((OpenHarmonyView)sliderCtl.Handler!.PlatformView!).SliderFraction:0.##}");
    Console.WriteLine($"[verify] slider drag handled={m} value={sliderCtl.Value:0.#} (virtual={sliderCtl.Value:0.#}, platform={platform.SliderValue:0.#})");
}

var spinnerCtl = root.Children.OfType<ActivityIndicator>().FirstOrDefault();
if (spinnerCtl is not null)
{
    var platform = (OpenHarmonyView)spinnerCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] indicator running={platform.IsRunning} needsAnimation={platform.NeedsAnimation}");
}

// Text input plumbing: mapper path, request API (no native host -> no-op), unfocus command.
if (entry is not null)
{
    entry.Text = "typed";
    var entryView = (OpenHarmonyView)entry.Handler!.PlatformView!;
    Console.WriteLine($"[verify] entry text mapped='{entryView.Text}' (virtual='{entry.Text}')");
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestTextInput(true);
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestTextInput(false);
    Console.WriteLine("[verify] RequestTextInput(show/hide) ok (no native host -> no-op)");
    ((IView)entry).Unfocus();
    Console.WriteLine($"[verify] entry unfocus platformFocused={entryView.IsFocused}");

    // W22-14: selection drag inside the entry.
    ((IView)entry).Focus();
    entryView.Text = "abcdefghij";
    Rect ef = entry.Frame;
    float ey = (float)(ef.Y + ef.Height / 2);
    entryView.TextAnchor = -1;
    host.HandleTouch(true, false, (float)(ef.X + ef.Width - 20), ey);
    host.HandleMove((float)(ef.X + 20), ey);
    host.HandleTouch(false, true, (float)(ef.X + 20), ey);
    entryView.TextAnchor = -1;
    Console.WriteLine($"[verify] selection drag cursor={entryView.CursorPosition} length={entryView.SelectionLength} virtual=({entry.CursorPosition},{entry.SelectionLength}) text='{entry.Text}'");
}

// Menus: the current page's MenuBarItems are published as a flat host table (begin/item/commit)
// and a shell tap (host.notifyMenuAction -> internal OnMenuAction) activates the source item
// through IMenuItemController. MenuFlyoutSubItems are flattened and MenuFlyoutSeparators are
// skipped; an item is enabled only when its bar is enabled too.
int menuClicks = 0;
int menuCommands = 0;
int menuDisabledClicks = 0;
var menuPage = new ContentPage { Title = "Menu page", Content = new Label { Text = "menu page" } };
var menuFileBar = new MenuBarItem { Text = "File" };
var menuNew = new MenuFlyoutItem { Text = "New", Command = new Command(() => menuCommands++) };
var menuOpen = new MenuFlyoutItem { Text = "Open" };
menuOpen.Clicked += (_, _) => menuClicks++;
menuFileBar.Add(menuNew);
menuFileBar.Add(new MenuFlyoutSeparator());
menuFileBar.Add(menuOpen);
var menuExport = new MenuFlyoutSubItem { Text = "Export" };
menuExport.Add(new MenuFlyoutItem { Text = "PDF" });
menuExport.Add(new MenuFlyoutItem { Text = "PNG", IsEnabled = false });
menuFileBar.Add(menuExport);
menuPage.MenuBarItems.Add(menuFileBar);
var menuEditBar = new MenuBarItem { Text = "Edit", IsEnabled = false };
var menuUndo = new MenuFlyoutItem { Text = "Undo" };
menuUndo.Clicked += (_, _) => menuDisabledClicks++;
menuEditBar.Add(menuUndo);
menuPage.MenuBarItems.Add(menuEditBar);

bool menuPublished = OpenHarmonyMenus.Refresh(menuPage);
Console.WriteLine($"[verify] menus table count={OpenHarmonyMenus.Items.Count} order=[{string.Join("|", OpenHarmonyMenus.Items.Select(m => $"{m.Index}:{m.Text}"))}] nativePublished={menuPublished} (no host library off-device)");
Console.WriteLine($"[verify] menus enabled=[{string.Join(",", OpenHarmonyMenus.Items.Select(m => m.IsEnabled ? "on" : "off"))}] depth=[{string.Join(",", OpenHarmonyMenus.Items.Select(m => m.Depth))}]");
Console.WriteLine($"[verify] menus publish intent wouldPublish={OpenHarmonyMenus.WouldPublish} lastPublished={OpenHarmonyMenus.LastPublishedCount} available={OpenHarmonyMenus.IsAvailable} (no host library off-device)");
bool menuActivated = OpenHarmonyMenus.OnMenuAction(0);
bool menuCommandActivated = OpenHarmonyMenus.OnMenuAction(1);
bool menuDisabledActivated = OpenHarmonyMenus.OnMenuAction(4);
Console.WriteLine($"[verify] menus activate click={menuActivated}/{menuClicks} command={menuCommandActivated}/{menuCommands} disabledBlocked={!menuDisabledActivated && menuDisabledClicks == 0}");

// An unchanged table is not republished; a different page replaces it (page-change sync).
int menuSkips = OpenHarmonyMenus.RefreshesSkipped;
bool menuRepublished = OpenHarmonyMenus.Refresh(menuPage);
var menuSecondPage = new ContentPage { Title = "Second", Content = new Label { Text = "second" } };
var menuViewBar = new MenuBarItem { Text = "View" };
var menuZoom = new MenuFlyoutItem { Text = "Zoom" };
menuZoom.Clicked += (_, _) => menuClicks++;
menuViewBar.Add(menuZoom);
menuSecondPage.MenuBarItems.Add(menuViewBar);
OpenHarmonyMenus.Refresh(menuSecondPage);
bool menuTableReplaced = OpenHarmonyMenus.Items.Count == 1 && OpenHarmonyMenus.Items[0].Text == "Zoom";
Console.WriteLine($"[verify] menus unchanged skip={!menuRepublished && OpenHarmonyMenus.RefreshesSkipped == menuSkips + 1} pageChangeReplaced={menuTableReplaced} count={OpenHarmonyMenus.Items.Count} text='{OpenHarmonyMenus.Items.FirstOrDefault()?.Text}'");

// Automatic page-change sync: a menu added to the host window's current page is picked up by
// the next platform redraw (the event navigation handlers raise on push/pop), no explicit call.
if (navRoot.CurrentPage is ContentPage livePage)
{
    var liveBar = new MenuBarItem { Text = "Live" };
    liveBar.Add(new MenuFlyoutItem { Text = "Live action" });
    livePage.MenuBarItems.Add(liveBar);
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestRedraw();
    Console.WriteLine($"[verify] menus auto sync on redraw={OpenHarmonyMenus.Items.Any(m => m.Text == "Live action")} count={OpenHarmonyMenus.Items.Count}");
}

// WebView JavaScript bridge (host ohos_host_web_eval/notifyWebEvalResult + shell
// registerWebEvalSink/notifyJsMessage): the managed handler must complete
// WebView.EvaluateJavaScriptAsync without throwing when no host library is present, and the
// native message callback (OnJsMessageNative -> HandleJsMessage) must raise JsMessage with the
// dotnetHost.postMessage payload.
var webProbe = new Microsoft.Maui.Controls.WebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(webProbe);
string? webEval = null;
bool webEvalThrew = false;
try
{
    webEval = await webProbe.EvaluateJavaScriptAsync("1 + 1");
}
catch (Exception ex)
{
    webEvalThrew = true;
    Console.WriteLine($"[verify] webview eval threw {ex.GetType().Name}: {ex.Message}");
}
bool webEvalOk = !webEvalThrew && webEval is null or "";
Console.WriteLine($"[verify] webview handler={webProbe.Handler?.GetType().Name ?? "null"} evaluateAsync completes={webEvalOk} result={(webEval is null ? "<null>" : $"'{webEval}'")} (no host library)");
if (!webEvalOk || webProbe.Handler is not OpenHarmonyWebViewHandler)
{
    throw new InvalidOperationException("WebView.EvaluateJavaScriptAsync did not degrade to null/empty off-device");
}

string? jsMessage = null;
void OnJsMessageProbe(string payload) => jsMessage = payload;
OpenHarmonyWebViewHandler.JsMessage += OnJsMessageProbe;
try
{
    // This is exactly what the native notifyJsMessage callback invokes (OnJsMessageNative).
    OpenHarmonyWebViewHandler.HandleJsMessage("{\"hello\":\"bridge\"}");
}
finally
{
    OpenHarmonyWebViewHandler.JsMessage -= OnJsMessageProbe;
}
bool jsMessageOk = jsMessage == "{\"hello\":\"bridge\"}";
Console.WriteLine($"[verify] webview JsMessage raised={jsMessageOk} payload='{jsMessage}'");
if (!jsMessageOk)
{
    throw new InvalidOperationException("the WebView JsMessage event did not carry the payload");
}

// HybridWebView: the MAUI contracts (EvaluateJavaScriptAsync/SendRawMessage/RawMessageReceived,
// plus InvokeJavaScriptAsync over the same message protocol) ride the same shell channel. The
// handler is registered in SliceHandlers, completes requests off-device instead of hanging, and
// inbound __RawMessage payloads (and plain dotnetHost payloads) reach RawMessageReceived.
bool hybridRegistered = MauiOpenHarmonyExtensions.SliceHandlers.TryGetValue(typeof(IHybridWebView), out Type? hybridType) &&
                        hybridType == typeof(OpenHarmonyHybridWebViewHandler);
var hybridProbe = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(hybridProbe);
string? hybridEval = null;
bool hybridEvalThrew = false;
try
{
    hybridEval = await hybridProbe.EvaluateJavaScriptAsync("1 + 1");
}
catch (Exception ex)
{
    hybridEvalThrew = true;
    Console.WriteLine($"[verify] hybrid eval threw {ex.GetType().Name}: {ex.Message}");
}
bool hybridEvalOk = !hybridEvalThrew && hybridEval is null or "";
Console.WriteLine($"[verify] hybrid handler={hybridProbe.Handler?.GetType().Name ?? "null"} registered={hybridRegistered} evaluateAsync completes={hybridEvalOk} result={(hybridEval is null ? "<null>" : $"'{hybridEval}'")} (no host library; asset registration is a no-op off-device)");
if (!hybridRegistered || hybridProbe.Handler is not OpenHarmonyHybridWebViewHandler || !hybridEvalOk)
{
    throw new InvalidOperationException("the HybridWebView handler assertion failed");
}

string? hybridRaw = null;
hybridProbe.RawMessageReceived += (_, e) => hybridRaw = e.Message;
bool hybridSendThrew = false;
try
{
    hybridProbe.SendRawMessage("raw-from-dotnet");
}
catch (Exception ex)
{
    hybridSendThrew = true;
    Console.WriteLine($"[verify] hybrid send threw {ex.GetType().Name}: {ex.Message}");
}
OpenHarmonyHybridWebViewHandler.OnJsMessage("__RawMessage|" + Uri.EscapeDataString("hello <hybrid>"));
string rawPrefixed = hybridRaw ?? "<null>";
hybridRaw = null;
OpenHarmonyHybridWebViewHandler.OnJsMessage("plain payload");
string rawPlain = hybridRaw ?? "<null>";
bool hybridRawOk = !hybridSendThrew && rawPrefixed == "hello <hybrid>" && rawPlain == "plain payload";
Console.WriteLine($"[verify] hybrid SendRawMessage degrades={!hybridSendThrew} rawMessage prefixed='{rawPrefixed}' plain='{rawPlain}'");
if (!hybridRawOk)
{
    throw new InvalidOperationException("the HybridWebView raw message assertion failed");
}

// InvokeJavaScriptAsync rides the same protocol (window.HybridWebView.__InvokeJavaScript ->
// __InvokeJavaScriptCompleted). Without a host library the kickoff cannot reach a page, so the
// contract must complete instead of leaving the caller waiting for the timeout.
bool hybridInvokeOk = false;
bool hybridInvokeThrew = false;
try
{
    await hybridProbe.InvokeJavaScriptAsync("verifyNoop");
    hybridInvokeOk = true;
}
catch (Exception ex)
{
    hybridInvokeThrew = true;
    Console.WriteLine($"[verify] hybrid invoke threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] hybrid InvokeJavaScriptAsync completes={hybridInvokeOk} (no host library -> null, no hang)");
if (!hybridInvokeOk || hybridInvokeThrew)
{
    throw new InvalidOperationException("the HybridWebView InvokeJavaScriptAsync path did not complete off-device");
}

// Hybrid asset serving: the shell serves the app package (https://0.0.0.1/ -> <base>/<root>)
// and the framework bootstrap script (<base>/_framework/hybridwebview.js) through the ArkWeb
// component's request interception; the handler extracts that script out of the Microsoft.Maui
// assembly, so the resource name it uses is pinned here.
bool hybridScriptEmbedded;
using (Stream? hybridScript = typeof(Microsoft.Maui.Handlers.HybridWebViewHandler).Assembly
           .GetManifestResourceStream(OpenHarmonyHybridWebViewHandler.HybridWebViewScriptPath))
{
    hybridScriptEmbedded = hybridScript is not null;
}
Console.WriteLine($"[verify] hybrid bootstrap resource '{OpenHarmonyHybridWebViewHandler.HybridWebViewScriptPath}' embedded={hybridScriptEmbedded} origin={OpenHarmonyHybridWebViewHandler.HybridAppOrigin}");
if (!hybridScriptEmbedded)
{
    throw new InvalidOperationException("the HybridWebView bootstrap script resource was not found");
}

// JS -> .NET invocation (__hwvInvokeDotNet): the shell holds the intercepted fetch open with
// setResponseIsReady(false), forwards method + JSON parameter array through
// host.notifyHybridInvoke, and completes the response with the DotNetInvokeResult payload the
// managed handler produces. Off-device the native export is absent, so the payload is
// observed through HybridInvokeResultSent (the same payload a device sends through
// ohos_host_hwv_invoke_result). Every branch must answer - the page's fetch must never hang.
var invokeResults = new Dictionary<int, string>();
void OnHybridInvokeResult(int requestId, string payload) => invokeResults[requestId] = payload;
OpenHarmonyHybridWebViewHandler.HybridInvokeResultSent += OnHybridInvokeResult;
hybridProbe.SetInvokeJavaScriptTarget(new VerifyHybridInvokeTarget());

int invokeEchoId = 91001;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeEchoId, "Echo", "[\"\\\"hi\\\"\"]");
bool invokeEchoOk = invokeResults.TryGetValue(invokeEchoId, out string? echoPayload)
    && PayloadBool(echoPayload, "IsError") == false
    && PayloadBool(echoPayload, "IsJson") == true
    && PayloadString(echoPayload, "Result") == "\"echo:hi\"";
Console.WriteLine($"[verify] hybrid InvokeDotNet round trip method=Echo result={PayloadString(invokeResults.GetValueOrDefault(invokeEchoId), "Result")} payload={invokeResults.GetValueOrDefault(invokeEchoId)}");
if (!invokeEchoOk)
{
    throw new InvalidOperationException("the HybridWebView __hwvInvokeDotNet round trip assertion failed");
}

int invokeAddId = 91002;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeAddId, "Add", "[\"20\",\"22\"]");
bool invokeAddOk = invokeResults.TryGetValue(invokeAddId, out string? addPayload)
    && PayloadBool(addPayload, "IsError") == false
    && PayloadString(addPayload, "Result") == "42";
Console.WriteLine($"[verify] hybrid InvokeDotNet typed result method=Add result={PayloadString(invokeResults.GetValueOrDefault(invokeAddId), "Result")}");
if (!invokeAddOk)
{
    throw new InvalidOperationException("the HybridWebView typed __hwvInvokeDotNet result assertion failed");
}

int invokeMissingId = 91003;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeMissingId, "NoSuchMethod", "[]");
bool invokeMissingOk = invokeResults.TryGetValue(invokeMissingId, out string? missingPayload)
    && PayloadBool(missingPayload, "IsError") == true
    && !string.IsNullOrEmpty(PayloadString(missingPayload, "ErrorMessage"));
Console.WriteLine($"[verify] hybrid InvokeDotNet missing method degrades to an error payload message='{PayloadString(invokeResults.GetValueOrDefault(invokeMissingId), "ErrorMessage")}'");
if (!invokeMissingOk)
{
    throw new InvalidOperationException("the HybridWebView missing-method error payload assertion failed");
}

int invokeBadArgsId = 91004;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeBadArgsId, "Echo", "not-json");
bool invokeBadArgsOk = invokeResults.TryGetValue(invokeBadArgsId, out string? badArgsPayload)
    && PayloadBool(badArgsPayload, "IsError") == true;
Console.WriteLine($"[verify] hybrid InvokeDotNet bad parameter JSON degrades to an error payload message='{PayloadString(invokeResults.GetValueOrDefault(invokeBadArgsId), "ErrorMessage")}'");
if (!invokeBadArgsOk)
{
    throw new InvalidOperationException("the HybridWebView bad-parameter error payload assertion failed");
}

// Honest degradation: a page without an InvokeJavaScriptTarget and a disconnected shell both
// answer an error payload instead of leaving the intercepted fetch open.
var hybridNoTarget = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(hybridNoTarget);
int invokeNoTargetId = 91005;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeNoTargetId, "Echo", "[]");
bool invokeNoTargetOk = invokeResults.TryGetValue(invokeNoTargetId, out string? noTargetPayload)
    && PayloadBool(noTargetPayload, "IsError") == true
    && PayloadString(noTargetPayload, "ErrorMessage")?.Contains("invoker", StringComparison.OrdinalIgnoreCase) == true;
Console.WriteLine($"[verify] hybrid InvokeDotNet without an InvokeJavaScriptTarget degrades message='{PayloadString(invokeResults.GetValueOrDefault(invokeNoTargetId), "ErrorMessage")}'");
if (!invokeNoTargetOk)
{
    throw new InvalidOperationException("the HybridWebView no-invoker error payload assertion failed");
}

hybridNoTarget.Handler?.DisconnectHandler();
hybridNoTarget.Handler = null;
int invokeNoPageId = 91006;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeNoPageId, "Echo", "[]");
bool invokeNoPageOk = invokeResults.TryGetValue(invokeNoPageId, out string? noPagePayload)
    && PayloadBool(noPagePayload, "IsError") == true
    && !string.IsNullOrEmpty(PayloadString(noPagePayload, "ErrorMessage"));
Console.WriteLine($"[verify] hybrid InvokeDotNet without a registered page degrades message='{PayloadString(invokeResults.GetValueOrDefault(invokeNoPageId), "ErrorMessage")}'");
if (!invokeNoPageOk)
{
    throw new InvalidOperationException("the HybridWebView no-page error payload assertion failed");
}

bool invokeBridgeDegraded = !OpenHarmonyHybridWebViewHandler.IsInvokeBridgeAvailable && invokeResults.Count == 6;
Console.WriteLine($"[verify] hybrid invoke bridge hostLibraryPresent={OpenHarmonyHybridWebViewHandler.IsInvokeBridgeAvailable} payloads={invokeResults.Count} allCompleted={invokeBridgeDegraded}");
if (!invokeBridgeDegraded)
{
    throw new InvalidOperationException("the HybridWebView invoke bridge degradation assertion failed");
}
OpenHarmonyHybridWebViewHandler.HybridInvokeResultSent -= OnHybridInvokeResult;

static bool PayloadBool(string? payload, string name)
    => !string.IsNullOrEmpty(payload) && JsonDocument.Parse(payload).RootElement.GetProperty(name).GetBoolean();

static string? PayloadString(string? payload, string name)
    => string.IsNullOrEmpty(payload) ? null : JsonDocument.Parse(payload).RootElement.GetProperty(name).GetString();

// Gap 5: Contacts/Calendar platform extras over the host/ArkTS kit bridge
// (ohos_host_contacts_query / ohos_host_calendar_list / ohos_host_calendar_add ->
// shell registerContactsSink / registerCalendarSink -> @kit.ContactsKit / @kit.CalendarKit).
// Off-device there is no libopenharmonyhost.so, so both must return empty/false without throwing
// and report IsSupported == false; the wire parsers are proven with the exact delimited payload
// shape the shell sends ("name\tphone" and "title\tstartIso\tendIso" lines).
bool contactsSupportedBefore = OpenHarmonyContacts.IsSupported;
IReadOnlyList<OpenHarmonyContact> contactsFound = Array.Empty<OpenHarmonyContact>();
bool contactsThrew = false;
try
{
    contactsFound = await OpenHarmonyContacts.FindAsync("ver", 5);
}
catch (Exception ex)
{
    contactsThrew = true;
    Console.WriteLine($"[verify] contacts FindAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool contactsDegraded = !contactsThrew && contactsFound.Count == 0 &&
    !contactsSupportedBefore && !OpenHarmonyContacts.IsSupported;
Console.WriteLine($"[verify] contacts FindAsync degraded without throwing={!contactsThrew} count={contactsFound.Count} supported(before={contactsSupportedBefore}, after={OpenHarmonyContacts.IsSupported})");
if (!contactsDegraded)
{
    throw new InvalidOperationException("OpenHarmonyContacts.FindAsync did not degrade off-device");
}

var contactsParsed = OpenHarmonyContacts.Parse("Ada Lovelace\t+15550100\nGrace Hopper\t+15550101\nNo Phone\n");
bool contactsParsedOk = contactsParsed.Count == 3 &&
    contactsParsed[0] == new OpenHarmonyContact("Ada Lovelace", "+15550100") &&
    contactsParsed[1] == new OpenHarmonyContact("Grace Hopper", "+15550101") &&
    contactsParsed[2] == new OpenHarmonyContact("No Phone", string.Empty);
Console.WriteLine($"[verify] contacts parser count={contactsParsed.Count} first='{contactsParsed[0].Name}/{contactsParsed[0].Phone}' second='{contactsParsed[1].Name}/{contactsParsed[1].Phone}' assert={contactsParsedOk}");
if (!contactsParsedOk)
{
    throw new InvalidOperationException("the contacts payload parser assertion failed");
}

bool calendarSupportedBefore = OpenHarmonyCalendar.IsSupported;
IReadOnlyList<OpenHarmonyCalendarEvent> upcoming = Array.Empty<OpenHarmonyCalendarEvent>();
bool calendarListThrew = false;
try
{
    upcoming = await OpenHarmonyCalendar.ListUpcomingAsync(7);
}
catch (Exception ex)
{
    calendarListThrew = true;
    Console.WriteLine($"[verify] calendar ListUpcomingAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool calendarDegraded = !calendarListThrew && upcoming.Count == 0 &&
    !calendarSupportedBefore && !OpenHarmonyCalendar.IsSupported;
Console.WriteLine($"[verify] calendar ListUpcomingAsync degraded without throwing={!calendarListThrew} count={upcoming.Count} supported(before={calendarSupportedBefore}, after={OpenHarmonyCalendar.IsSupported})");
if (!calendarDegraded)
{
    throw new InvalidOperationException("OpenHarmonyCalendar.ListUpcomingAsync did not degrade off-device");
}

bool addReturned = true;
bool calendarAddThrew = false;
try
{
    addReturned = await OpenHarmonyCalendar.AddEventAsync(
        "Verify event", "2026-09-19T09:00:00.000Z", "2026-09-19T10:00:00.000Z");
}
catch (Exception ex)
{
    calendarAddThrew = true;
    Console.WriteLine($"[verify] calendar AddEventAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool calendarAddDegraded = !calendarAddThrew && !addReturned;
Console.WriteLine($"[verify] calendar AddEventAsync degraded without throwing={!calendarAddThrew} returned={addReturned}");
if (!calendarAddDegraded)
{
    throw new InvalidOperationException("OpenHarmonyCalendar.AddEventAsync did not degrade off-device");
}

var eventsParsed = OpenHarmonyCalendar.Parse(
    "Team sync\t2026-09-19T09:00:00.000Z\t2026-09-19T10:00:00.000Z\n" +
    "Local standup\t2026-09-20T09:30:00+08:00\t2026-09-20T09:45:00+08:00\n" +
    "broken line\n" +
    "Bad dates\tnot-a-date\t2026-09-20T10:00:00.000Z\n");
bool calendarParsedOk = eventsParsed.Count == 2 &&
    eventsParsed[0].Title == "Team sync" &&
    eventsParsed[0].Start == DateTimeOffset.Parse("2026-09-19T09:00:00.000Z", System.Globalization.CultureInfo.InvariantCulture) &&
    eventsParsed[0].End == DateTimeOffset.Parse("2026-09-19T10:00:00.000Z", System.Globalization.CultureInfo.InvariantCulture) &&
    eventsParsed[1].Title == "Local standup" &&
    eventsParsed[1].Start == DateTimeOffset.Parse("2026-09-20T09:30:00+08:00", System.Globalization.CultureInfo.InvariantCulture);
Console.WriteLine($"[verify] calendar parser count={eventsParsed.Count} first='{eventsParsed[0].Title}/{eventsParsed[0].Start:O}' splitLinesDropped={eventsParsed.Count == 2} assert={calendarParsedOk}");
if (!calendarParsedOk)
{
    throw new InvalidOperationException("the calendar payload parser assertion failed");
}

// Gap 6: Bluetooth/Printing platform extras over the same host/ArkTS kit bridge
// (ohos_host_bluetooth_query -> shell registerBluetoothSink -> @kit.ConnectivityKit
// access/connection; ohos_host_print_file -> shell registerPrintSink -> @ohos.print).
// Off-device there is no libopenharmonyhost.so, so every call must return false/empty without
// throwing and report IsSupported == false; the paired-device/state parsers and the text->PDF
// renderer are exercised with simulated payloads.
bool bluetoothSupportedBefore = OpenHarmonyBluetooth.IsSupported;
bool bluetoothEnabled = true;
bool bluetoothEnabledThrew = false;
try
{
    bluetoothEnabled = await OpenHarmonyBluetooth.IsEnabledAsync();
}
catch (Exception ex)
{
    bluetoothEnabledThrew = true;
    Console.WriteLine($"[verify] bluetooth IsEnabledAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool bluetoothEnabledDegraded = !bluetoothEnabledThrew && !bluetoothEnabled &&
    !bluetoothSupportedBefore && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth IsEnabledAsync degraded without throwing={!bluetoothEnabledThrew} enabled={bluetoothEnabled} supported(before={bluetoothSupportedBefore}, after={OpenHarmonyBluetooth.IsSupported})");
if (!bluetoothEnabledDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.IsEnabledAsync did not degrade off-device");
}

IReadOnlyList<OpenHarmonyBluetoothDevice> pairedDevices = Array.Empty<OpenHarmonyBluetoothDevice>();
bool pairedThrew = false;
try
{
    pairedDevices = await OpenHarmonyBluetooth.GetPairedDevicesAsync();
}
catch (Exception ex)
{
    pairedThrew = true;
    Console.WriteLine($"[verify] bluetooth GetPairedDevicesAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool pairedDegraded = !pairedThrew && pairedDevices.Count == 0 && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth GetPairedDevicesAsync degraded without throwing={!pairedThrew} count={pairedDevices.Count} supported={OpenHarmonyBluetooth.IsSupported}");
if (!pairedDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.GetPairedDevicesAsync did not degrade off-device");
}

bool discoveryStarted = true;
bool discoveryStopped = true;
bool discoveryThrew = false;
try
{
    discoveryStarted = await OpenHarmonyBluetooth.StartDiscoveryAsync();
    discoveryStopped = await OpenHarmonyBluetooth.StopDiscoveryAsync();
}
catch (Exception ex)
{
    discoveryThrew = true;
    Console.WriteLine($"[verify] bluetooth discovery threw {ex.GetType().Name}: {ex.Message}");
}
bool discoveryDegraded = !discoveryThrew && !discoveryStarted && !discoveryStopped;
Console.WriteLine($"[verify] bluetooth discovery degraded without throwing={!discoveryThrew} started={discoveryStarted} stopped={discoveryStopped}");
if (!discoveryDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth discovery did not degrade off-device");
}

var pairedParsed = OpenHarmonyBluetooth.ParsePairedDevices(
    "QuietComfort\tAA:BB:CC:DD:EE:01\n\tAA:BB:CC:DD:EE:02\nNoAddressOnly\n");
bool pairedParsedOk = pairedParsed.Count == 3 &&
    pairedParsed[0] == new OpenHarmonyBluetoothDevice("QuietComfort", "AA:BB:CC:DD:EE:01") &&
    pairedParsed[1] == new OpenHarmonyBluetoothDevice(string.Empty, "AA:BB:CC:DD:EE:02") &&
    pairedParsed[2] == new OpenHarmonyBluetoothDevice(string.Empty, "NoAddressOnly");
Console.WriteLine($"[verify] bluetooth paired parser count={pairedParsed.Count} first='{pairedParsed[0].Name}/{pairedParsed[0].Address}' nameless='{pairedParsed[1].Address}' assert={pairedParsedOk}");
if (!pairedParsedOk)
{
    throw new InvalidOperationException("the bluetooth paired-device payload parser assertion failed");
}

bool stateOn = OpenHarmonyBluetooth.ParseAdapterState("2");
bool stateOff = OpenHarmonyBluetooth.ParseAdapterState("0");
bool stateTurningOn = OpenHarmonyBluetooth.ParseAdapterState("1");
bool stateGarbage = OpenHarmonyBluetooth.ParseAdapterState("nope") ||
    OpenHarmonyBluetooth.ParseAdapterState(null);
bool stateParsedOk = stateOn && !stateOff && !stateTurningOn && !stateGarbage;
Console.WriteLine($"[verify] bluetooth state parser on={stateOn} off={stateOff} turningOn={stateTurningOn} garbage={stateGarbage} assert={stateParsedOk}");
if (!stateParsedOk)
{
    throw new InvalidOperationException("the bluetooth adapter-state parser assertion failed");
}

// Discovery devices (Gap 6 follow-up): op 4 returns the bluetoothDeviceFind table, each device
// also arrives as a pushed DeviceFound event. Off-device both must degrade without throwing.
IReadOnlyList<OpenHarmonyBluetoothDevice> discoveredDevices = Array.Empty<OpenHarmonyBluetoothDevice>();
bool discoveredThrew = false;
try
{
    discoveredDevices = await OpenHarmonyBluetooth.GetDiscoveredDevicesAsync();
}
catch (Exception ex)
{
    discoveredThrew = true;
    Console.WriteLine($"[verify] bluetooth GetDiscoveredDevicesAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool discoveredDegraded = !discoveredThrew && discoveredDevices.Count == 0 && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth GetDiscoveredDevicesAsync degraded without throwing={!discoveredThrew} count={discoveredDevices.Count} supported={OpenHarmonyBluetooth.IsSupported}");
if (!discoveredDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.GetDiscoveredDevicesAsync did not degrade off-device");
}

var discoveredParsed = OpenHarmonyBluetooth.ParseDevices(
    "QuietComfort\tAA:BB:CC:DD:EE:01\n\tAA:BB:CC:DD:EE:02\nNoAddressOnly\n");
bool parseDevicesOk = discoveredParsed.Count == 3 &&
    discoveredParsed[0] == new OpenHarmonyBluetoothDevice("QuietComfort", "AA:BB:CC:DD:EE:01") &&
    discoveredParsed[1] == new OpenHarmonyBluetoothDevice(string.Empty, "AA:BB:CC:DD:EE:02") &&
    OpenHarmonyBluetooth.ParsePairedDevices(null).Count == 0 &&
    OpenHarmonyBluetooth.ParsePairedDevices("X\tY").Count == 1 &&
    OpenHarmonyBluetooth.ParsePairedDevices("X\tY")[0] == new OpenHarmonyBluetoothDevice("X", "Y");
Console.WriteLine($"[verify] bluetooth device parser count={discoveredParsed.Count} first='{discoveredParsed[0].Name}/{discoveredParsed[0].Address}' nameless='{discoveredParsed[1].Address}' pairedDelegates=True assert={parseDevicesOk}");
if (!parseDevicesOk)
{
    throw new InvalidOperationException("the bluetooth device payload parser assertion failed");
}

string? foundName = null;
string? foundAddress = null;
int foundCount = 0;
EventHandler<OpenHarmonyBluetoothDevice> onDeviceFound = (_, device) =>
{
    foundName = device.Name;
    foundAddress = device.Address;
    foundCount++;
};
OpenHarmonyBluetooth.DeviceFound += onDeviceFound;
bool foundThrew = false;
try
{
    OpenHarmonyBluetooth.OnDeviceFoundPayload("Headset\t11:22:33:44:55:66");
    OpenHarmonyBluetooth.OnDeviceFoundPayload(null);
    OpenHarmonyBluetooth.OnDeviceFoundPayload("malformed-without-tab-is-still-a-device");
    OpenHarmonyBluetooth.OnDeviceFoundPayload(string.Empty);
}
catch (Exception ex)
{
    foundThrew = true;
    Console.WriteLine($"[verify] bluetooth DeviceFound payload threw {ex.GetType().Name}: {ex.Message}");
}
OpenHarmonyBluetooth.DeviceFound -= onDeviceFound;
// The tabless record is a valid address-only entry, so exactly the two non-empty records raise
// (the second one with an empty name).
bool deviceFoundOk = !foundThrew && foundCount == 2 && foundName == string.Empty &&
    foundAddress == "malformed-without-tab-is-still-a-device";
Console.WriteLine($"[verify] bluetooth DeviceFound event count={foundCount} last='{foundName}/{foundAddress}' noThrow={!foundThrew} assert={deviceFoundOk}");
if (!deviceFoundOk)
{
    throw new InvalidOperationException("the bluetooth DeviceFound event assertion failed");
}

bool printingSupportedBefore = OpenHarmonyPrinting.IsSupported;
bool printMissingReturned = true;
bool printMissingThrew = false;
try
{
    printMissingReturned = await OpenHarmonyPrinting.PrintFileAsync(
        Path.Combine(FileSystem.CacheDirectory, "verify-missing-print-file.pdf"));
}
catch (Exception ex)
{
    printMissingThrew = true;
    Console.WriteLine($"[verify] printing PrintFileAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool printMissingDegraded = !printMissingThrew && !printMissingReturned &&
    !printingSupportedBefore && !OpenHarmonyPrinting.IsSupported;
Console.WriteLine($"[verify] printing PrintFileAsync missing-file degraded without throwing={!printMissingThrew} returned={printMissingReturned} supported(before={printingSupportedBefore}, after={OpenHarmonyPrinting.IsSupported})");
if (!printMissingDegraded)
{
    throw new InvalidOperationException("OpenHarmonyPrinting.PrintFileAsync did not degrade off-device");
}

bool printTextReturned = true;
bool printTextThrew = false;
try
{
    printTextReturned = await OpenHarmonyPrinting.PrintTextAsync("verify text", "Hello printing\nSecond line");
}
catch (Exception ex)
{
    printTextThrew = true;
    Console.WriteLine($"[verify] printing PrintTextAsync threw {ex.GetType().Name}: {ex.Message}");
}
string textPdfPath = Path.Combine(FileSystem.CacheDirectory, "verify_text.pdf");
bool textPdfWritten = File.Exists(textPdfPath) &&
    System.Text.Encoding.ASCII.GetString(File.ReadAllBytes(textPdfPath), 0, 8) == "%PDF-1.4";
bool printTextDegraded = !printTextThrew && !printTextReturned && !OpenHarmonyPrinting.IsSupported;
Console.WriteLine($"[verify] printing PrintTextAsync degraded without throwing={!printTextThrew} returned={printTextReturned} wrotePdf={textPdfWritten} supported={OpenHarmonyPrinting.IsSupported}");
if (!printTextDegraded || !textPdfWritten)
{
    throw new InvalidOperationException("OpenHarmonyPrinting.PrintTextAsync did not degrade off-device");
}
File.Delete(textPdfPath);

byte[] textPdf = OpenHarmonyPrinting.BuildTextPdf(
    "Hello print\nLine two\n\nEscapes (paren) and \\ slash\nCafe\u00e9");
string pdfAscii = System.Text.Encoding.ASCII.GetString(textPdf);
int startxrefIndex = pdfAscii.LastIndexOf("startxref\n", StringComparison.Ordinal);
int pdfXrefOffset = -1;
if (startxrefIndex >= 0)
{
    int valueStart = startxrefIndex + "startxref\n".Length;
    int valueEnd = pdfAscii.IndexOf('\n', valueStart);
    if (valueEnd > valueStart)
    {
        int.TryParse(pdfAscii.AsSpan(valueStart, valueEnd - valueStart), out pdfXrefOffset);
    }
}
// Skip the "xref" line, the "0 <count>" line and the free entry to reach object 1's entry.
int firstXrefEntry = pdfAscii.IndexOf('\n', pdfXrefOffset) + 1;
firstXrefEntry = pdfAscii.IndexOf('\n', firstXrefEntry) + 1;
firstXrefEntry = pdfAscii.IndexOf('\n', firstXrefEntry) + 1;
int firstObjectOffset = -1;
if (firstXrefEntry > 0)
{
    int.TryParse(pdfAscii.AsSpan(firstXrefEntry, 10), out firstObjectOffset);
}
// Every xref entry (1..Size-1) must point at its "<n> 0 obj" header.
int pdfSizeStart = pdfAscii.IndexOf("/Size ", StringComparison.Ordinal) + "/Size ".Length;
int pdfSizeEnd = pdfAscii.IndexOf(' ', pdfSizeStart);
int pdfObjectCount = 0;
if (pdfSizeStart > 0 && pdfSizeEnd > pdfSizeStart)
{
    int.TryParse(pdfAscii.AsSpan(pdfSizeStart, pdfSizeEnd - pdfSizeStart), out pdfObjectCount);
}
bool xrefEntriesOk = pdfObjectCount > 1;
int xrefEntryCursor = firstXrefEntry;
for (int i = 1; i < pdfObjectCount && xrefEntriesOk; i++)
{
    int entryOffset = -1;
    if (xrefEntryCursor > 0)
    {
        int.TryParse(pdfAscii.AsSpan(xrefEntryCursor, 10), out entryOffset);
    }
    string expectedHeader = $"{i} 0 obj";
    xrefEntriesOk = entryOffset > 0 && entryOffset + expectedHeader.Length <= pdfAscii.Length &&
        pdfAscii.Substring(entryOffset, expectedHeader.Length) == expectedHeader;
    xrefEntryCursor = pdfAscii.IndexOf('\n', xrefEntryCursor) + 1;
}
// Every content stream's declared /Length must be followed by endstream after optional
// whitespace (the EOL before the keyword may or may not be counted per writer style).
bool streamLengthsOk = true;
int streamCursor = 0;
while (true)
{
    // Anchored with the leading newline so the "stream" inside "endstream" never matches.
    int streamAt = pdfAscii.IndexOf("\nstream\n", streamCursor, StringComparison.Ordinal);
    if (streamAt < 0)
    {
        break;
    }
    int dataStart = streamAt + "\nstream\n".Length;
    int lengthAt = pdfAscii.LastIndexOf("/Length ", streamAt, StringComparison.Ordinal);
    int declaredLength = -1;
    if (lengthAt >= 0)
    {
        int lengthValueStart = lengthAt + "/Length ".Length;
        int lengthValueEnd = pdfAscii.IndexOf(' ', lengthValueStart);
        int.TryParse(pdfAscii.AsSpan(lengthValueStart, lengthValueEnd - lengthValueStart), out declaredLength);
    }
    int afterData = declaredLength >= 0 ? dataStart + declaredLength : -1;
    while (afterData >= 0 && afterData < pdfAscii.Length &&
        (pdfAscii[afterData] == '\r' || pdfAscii[afterData] == '\n' || pdfAscii[afterData] == ' '))
    {
        afterData++;
    }
    bool thisStreamOk = afterData >= 0 && afterData + "endstream".Length <= pdfAscii.Length &&
        pdfAscii.Substring(afterData, "endstream".Length) == "endstream";
    if (!thisStreamOk)
    {
        streamLengthsOk = false;
    }
    streamCursor = thisStreamOk ? afterData + "endstream".Length : pdfAscii.Length;
}
bool pdfOk = pdfAscii.StartsWith("%PDF-1.4", StringComparison.Ordinal) &&
    pdfAscii.EndsWith("%%EOF\n", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Type /Catalog", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Type /Pages", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Subtype /Type1", StringComparison.Ordinal) &&
    pdfAscii.Contains("(Escapes \\(paren\\) and \\\\ slash)", StringComparison.Ordinal) &&
    pdfAscii.Contains("\\351", StringComparison.Ordinal) &&
    pdfXrefOffset > 0 && pdfXrefOffset < pdfAscii.Length &&
    pdfAscii.Substring(pdfXrefOffset, 4) == "xref" &&
    firstObjectOffset > 0 && pdfAscii.Substring(firstObjectOffset, 7) == "1 0 obj" &&
    xrefEntriesOk && streamLengthsOk;
Console.WriteLine($"[verify] printing text pdf bytes={textPdf.Length} xref={pdfXrefOffset} objects={pdfObjectCount} xrefEntriesOk={xrefEntriesOk} streamLengthsOk={streamLengthsOk} assert={pdfOk}");
if (!pdfOk)
{
    throw new InvalidOperationException("the text-to-PDF document structure assertion failed");
}

byte[] longPdf = OpenHarmonyPrinting.BuildTextPdf(
    string.Join("\n", Enumerable.Range(0, 120).Select(i => $"print line {i}")));
string longPdfAscii = System.Text.Encoding.ASCII.GetString(longPdf);
bool longPdfOk = longPdfAscii.Contains("/Count 3", StringComparison.Ordinal) && longPdf.Length > textPdf.Length;
Console.WriteLine($"[verify] printing text pdf pagination bytes={longPdf.Length} pages=3 assert={longPdfOk}");
if (!longPdfOk)
{
    throw new InvalidOperationException("the multi-page text-to-PDF assertion failed");
}

string sanitized = OpenHarmonyPrinting.SanitizeJobName("verify text.pdf");
bool sanitizeOk = sanitized == "verify_text_pdf" &&
    OpenHarmonyPrinting.SanitizeJobName("  ") == "print" &&
    OpenHarmonyPrinting.SanitizeJobName(null) == "print";
Console.WriteLine($"[verify] printing job name sanitizer 'verify text.pdf'->'{sanitized}' empty->'{OpenHarmonyPrinting.SanitizeJobName(null)}' assert={sanitizeOk}");
if (!sanitizeOk)
{
    throw new InvalidOperationException("the print job name sanitizer assertion failed");
}

// Gap 6 follow-up: Battery/DeviceDisplay (Essentials) over the shell push bridge
// (host.notifyBattery / host.notifyDisplay -> the ModuleInitializer-installed implementations).
// Off-device the native registration is guarded, the properties stay at the documented defaults
// and the payload parsers are exercised with the exact shell formats.
bool batteryInstalled = Microsoft.Maui.Devices.Battery.Default is OpenHarmonyBattery;
Console.WriteLine($"[verify] battery default installed={batteryInstalled} type={Microsoft.Maui.Devices.Battery.Default.GetType().Name} instance={ReferenceEquals(Microsoft.Maui.Devices.Battery.Default, OpenHarmonyBattery.Instance)}");
if (!batteryInstalled)
{
    throw new InvalidOperationException("OpenHarmonyBattery was not installed as the Essentials Battery default");
}

OpenHarmonyBatterySnapshot? charging = OpenHarmonyBattery.ParseState("85\t1\t2\t1\t600");
OpenHarmonyBatterySnapshot? discharging = OpenHarmonyBattery.ParseState("50\t2\t1\t1\t601");
OpenHarmonyBatterySnapshot? fullAbsent = OpenHarmonyBattery.ParseState("100\t3\t3\t0\t603");
OpenHarmonyBatterySnapshot? ignored = OpenHarmonyBattery.ParseState("100\t3\t3\t0\t650");
bool batteryParsedOk = charging is { ChargeLevel: 0.85, State: BatteryState.Charging, PowerSource: BatteryPowerSource.Usb, EnergySaver: EnergySaverStatus.Off } &&
    discharging is { ChargeLevel: 0.5, State: BatteryState.Discharging, PowerSource: BatteryPowerSource.AC, EnergySaver: EnergySaverStatus.On } &&
    fullAbsent is { ChargeLevel: 1.0, State: BatteryState.NotPresent, PowerSource: BatteryPowerSource.Wireless, EnergySaver: EnergySaverStatus.On } &&
    ignored is { State: BatteryState.NotPresent, EnergySaver: EnergySaverStatus.On } &&
    OpenHarmonyBattery.ParseState("85\t1") is null &&
    OpenHarmonyBattery.ParseState("a\tb\tc\td\te") is null &&
    OpenHarmonyBattery.ParseState(null) is null;
Console.WriteLine($"[verify] battery parser charging={charging?.ChargeLevel}/{charging?.State}/{charging?.PowerSource}/{charging?.EnergySaver} discharging={discharging?.ChargeLevel}/{discharging?.State}/{discharging?.PowerSource}/{discharging?.EnergySaver} absent={fullAbsent?.State} customSaver={ignored?.EnergySaver} malformedNull={OpenHarmonyBattery.ParseState("85\t1") is null} assert={batteryParsedOk}");
if (!batteryParsedOk)
{
    throw new InvalidOperationException("the battery payload parser assertion failed");
}

bool batteryOffDeviceOk = true;
double batteryLevel = -1;
BatteryState batteryState = BatteryState.Unknown;
BatteryPowerSource batterySource = BatteryPowerSource.Unknown;
bool batteryEvents = false;
bool saverEvents = false;
EventHandler<BatteryInfoChangedEventArgs> onBatteryInfoChanged = (_, e) =>
{
    batteryLevel = e.ChargeLevel;
    batteryState = e.State;
    batterySource = e.PowerSource;
    batteryEvents = true;
};
EventHandler<EnergySaverStatusChangedEventArgs> onEnergySaverChanged = (_, e) =>
{
    saverEvents = e.EnergySaverStatus == EnergySaverStatus.On;
};
try
{
    Microsoft.Maui.Devices.Battery.BatteryInfoChanged += onBatteryInfoChanged;
    Microsoft.Maui.Devices.Battery.EnergySaverStatusChanged += onEnergySaverChanged;
    batteryOffDeviceOk = Microsoft.Maui.Devices.Battery.ChargeLevel == 0 &&
        Microsoft.Maui.Devices.Battery.State == BatteryState.Unknown &&
        Microsoft.Maui.Devices.Battery.PowerSource == BatteryPowerSource.Unknown &&
        Microsoft.Maui.Devices.Battery.EnergySaverStatus == EnergySaverStatus.Unknown;
    // The native-shaped payload push is the same path the host callback runs on-device.
    OpenHarmonyBattery.OnBatteryPayload("42\t2\t2\t1\t650");
    OpenHarmonyBattery.OnBatteryPayload("garbage");
}
catch (Exception ex)
{
    batteryOffDeviceOk = false;
    Console.WriteLine($"[verify] battery payload push threw {ex.GetType().Name}: {ex.Message}");
}
finally
{
    Microsoft.Maui.Devices.Battery.BatteryInfoChanged -= onBatteryInfoChanged;
    Microsoft.Maui.Devices.Battery.EnergySaverStatusChanged -= onEnergySaverChanged;
}
bool batteryPushOk = batteryOffDeviceOk && batteryEvents && saverEvents && batteryLevel == 0.42 &&
    batteryState == BatteryState.Discharging && batterySource == BatteryPowerSource.Usb &&
    Microsoft.Maui.Devices.Battery.EnergySaverStatus == EnergySaverStatus.On;
Console.WriteLine($"[verify] battery push level={batteryLevel} state={batteryState} source={batterySource} saver={Microsoft.Maui.Devices.Battery.EnergySaverStatus} infoEvents={batteryEvents} saverEvents={saverEvents} noThrow={batteryOffDeviceOk} assert={batteryPushOk}");
if (!batteryPushOk)
{
    throw new InvalidOperationException("the battery payload push assertion failed");
}

bool displayInstalled = Microsoft.Maui.Devices.DeviceDisplay.Current is OpenHarmonyDeviceDisplay;
Console.WriteLine($"[verify] display default installed={displayInstalled} type={Microsoft.Maui.Devices.DeviceDisplay.Current.GetType().Name} instance={ReferenceEquals(Microsoft.Maui.Devices.DeviceDisplay.Current, OpenHarmonyDeviceDisplay.Instance)}");
if (!displayInstalled)
{
    throw new InvalidOperationException("OpenHarmonyDeviceDisplay was not installed as the Essentials DeviceDisplay current");
}

DisplayInfo emptyInfo = Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfo;
DisplayInfo? portrait = OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0\t60\t0");
DisplayInfo? landscape = OpenHarmonyDeviceDisplay.ParseDisplayInfo("2340\t1080\t320\t3\t90\t3");
DisplayInfo? inferred = OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0\t60");
bool displayParsedOk = portrait is { Width: 1080, Height: 2340, Density: 3.0, Rotation: DisplayRotation.Rotation0, Orientation: DisplayOrientation.Portrait, RefreshRate: 60 } &&
    landscape is { Width: 2340, Height: 1080, Density: 2.0, Rotation: DisplayRotation.Rotation270, Orientation: DisplayOrientation.Landscape, RefreshRate: 90 } &&
    inferred is { Orientation: DisplayOrientation.Portrait } &&
    emptyInfo is { Width: 0, Height: 0, Density: 1, Rotation: DisplayRotation.Unknown, Orientation: DisplayOrientation.Unknown } &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo("x\ty\tz\t0\t60\t0") is null &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0") is null &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo(null) is null;
Console.WriteLine($"[verify] display parser portrait={portrait?.Width}x{portrait?.Height} density={portrait?.Density} rotation={portrait?.Rotation} orientation={portrait?.Orientation} landscape={landscape?.Width}x{landscape?.Height} rotation270={landscape?.Rotation == DisplayRotation.Rotation270} inferredOrientation={inferred?.Orientation} malformedNull={OpenHarmonyDeviceDisplay.ParseDisplayInfo("x\ty\tz\t0\t60\t0") is null} assert={displayParsedOk}");
if (!displayParsedOk)
{
    throw new InvalidOperationException("the display payload parser assertion failed");
}

DisplayInfo? changedInfo = null;
int displayChangedCount = 0;
EventHandler<DisplayInfoChangedEventArgs> onDisplayChanged = (_, e) =>
{
    changedInfo = e.DisplayInfo;
    displayChangedCount++;
};
bool displayPushOk;
try
{
    Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfoChanged += onDisplayChanged;
    OpenHarmonyDeviceDisplay.OnDisplayPayload("1080\t2340\t480\t0\t60\t0");
    DisplayInfo first = changedInfo ?? throw new InvalidOperationException("the display change event did not deliver a display info");
    OpenHarmonyDeviceDisplay.OnDisplayPayload("1080\t2340\t480\t0\t60\t0");   // identical -> no second raise
    OpenHarmonyDeviceDisplay.OnDisplayPayload("2340\t1080\t320\t3\t90\t3");
    OpenHarmonyDeviceDisplay.OnDisplayPayload("garbage");
    displayPushOk = displayChangedCount == 2 && first.Width == 1080 && first.Density == 3.0 &&
        changedInfo is { Width: 2340, Rotation: DisplayRotation.Rotation270 } &&
        Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfo.Width == 2340;
}
catch (Exception ex)
{
    displayPushOk = false;
    Console.WriteLine($"[verify] display payload push threw {ex.GetType().Name}: {ex.Message}");
}
finally
{
    Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfoChanged -= onDisplayChanged;
}
bool keepScreenOnOk = !Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn;
try
{
    Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn = true;
    keepScreenOnOk = !Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn;
}
catch (Exception)
{
    keepScreenOnOk = false;
}
Console.WriteLine($"[verify] display push changed={displayChangedCount} final={changedInfo?.Width}x{changedInfo?.Height} density={changedInfo?.Density} rotation={changedInfo?.Rotation} keepScreenOnFalse={keepScreenOnOk} noThrow={displayPushOk}");
if (!displayPushOk || !keepScreenOnOk)
{
    throw new InvalidOperationException("the display payload push assertion failed");
}
Console.WriteLine($"[verify] display off-device info={emptyInfo.Width}x{emptyInfo.Height} density={emptyInfo.Density} rotation={emptyInfo.Rotation} orientation={emptyInfo.Orientation} (empty default asserted)");

// ---- Deterministic fuzz (bounded, seeded) -----------------------------------------------------
// A seeded storm of touch sequences with extreme but finite (mostly out-of-bounds) coordinates,
// two very long strings through the simulated bridge payloads and a ~300-node deep view tree that
// drives the iterative accessibility/diagnostics walks. It is bounded (300 sequences, 32-48 KiB
// payloads, no big buffers), deterministic (fixed seed) and must finish in seconds, so it asserts
// "no unhandled exception, no hang" without slowing the suite down.
var fuzzWatch = System.Diagnostics.Stopwatch.StartNew();
var fuzzRandom = new Random(20260920);   // fixed seed -> identical sequences on every run
string fuzzTouchResult = "no throw";
for (int i = 0; i < 300; i++)
{
    // Every fifth sequence lands inside the 1080x1920 surface; the rest uses finite but extreme
    // coordinates (including +-float.MaxValue) that no device would ever produce.
    float x0, y0, x1, y1;
    if (i % 5 == 0)
    {
        x0 = (float)(fuzzRandom.NextDouble() * 1080);
        y0 = (float)(fuzzRandom.NextDouble() * 1920);
        x1 = (float)(fuzzRandom.NextDouble() * 1080);
        y1 = (float)(fuzzRandom.NextDouble() * 1920);
    }
    else if (i % 97 == 0)
    {
        x0 = float.MaxValue; y0 = -float.MaxValue;
        x1 = float.MinValue; y1 = float.MaxValue;
    }
    else
    {
        x0 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        y0 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        x1 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        y1 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
    }
    try
    {
        host.HandleTouch(true, false, x0, y0);
        for (int moves = fuzzRandom.Next(3); moves > 0; moves--)
        {
            host.HandleMove((float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000),
                            (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000));
        }
        host.HandleTouch(false, true, x1, y1);
    }
    catch (Exception ex)
    {
        fuzzTouchResult = $"sequence {i} threw {ex.GetType().Name}: {ex.Message}";
        break;
    }
}
Console.WriteLine($"[verify] fuzz touch sequences=300 seed=20260920 extreme=finite out-of-bounds=true result={fuzzTouchResult}");
if (fuzzTouchResult != "no throw")
{
    throw new InvalidOperationException($"the seeded touch fuzz raised {fuzzTouchResult}");
}

// Two very long payloads through the simulated JS -> .NET bridge: the HybridWebView
// __RawMessage channel (escaped/unescaped) and the native notifyJsMessage callback, both must
// round-trip the full string without throwing.
string fuzzLongRaw = new string('r', 32 * 1024);
string fuzzLongJson = new string('j', 48 * 1024);
string? fuzzRawSeen = null;
string? fuzzJsSeen = null;
void FuzzOnJs(string payload) => fuzzJsSeen = payload;
hybridProbe.RawMessageReceived += (_, e) => fuzzRawSeen = e.Message;
OpenHarmonyWebViewHandler.JsMessage += FuzzOnJs;
string fuzzPayloadResult;
try
{
    OpenHarmonyHybridWebViewHandler.OnJsMessage("__RawMessage|" + Uri.EscapeDataString(fuzzLongRaw));
    string? fuzzRawAfterHybrid = fuzzRawSeen;
    OpenHarmonyWebViewHandler.HandleJsMessage("{\"pad\":\"" + fuzzLongJson + "\"}");
    string expectedJson = "{\"pad\":\"" + fuzzLongJson + "\"}";
    // The native WebView callback is also fanned out to the HybridWebView raw channel (the shell
    // routes every dotnetHost.postMessage payload through it), so the raw probe sees the JSON
    // payload as well after the second call.
    fuzzPayloadResult = fuzzRawAfterHybrid == fuzzLongRaw && fuzzJsSeen == expectedJson
        ? "round-trip ok"
        : $"hybrid={fuzzRawAfterHybrid?.Length ?? -1} js={fuzzJsSeen?.Length ?? -1} rawAfterJs={fuzzRawSeen?.Length ?? -1}";
}
catch (Exception ex)
{
    fuzzPayloadResult = $"{ex.GetType().Name}: {ex.Message}";
}
finally
{
    OpenHarmonyWebViewHandler.JsMessage -= FuzzOnJs;
}
Console.WriteLine($"[verify] fuzz bridge payloads raw={fuzzLongRaw.Length}B json={fuzzLongJson.Length}B result={fuzzPayloadResult}");
if (fuzzPayloadResult != "round-trip ok")
{
    throw new InvalidOperationException($"the long bridge payload fuzz failed: {fuzzPayloadResult}");
}

// A ~300-node deep tree (150 nested layouts, each with a label) through the iterative walks:
// OpenHarmonyAccessibility.Visit (the Stack-based shadow tree) and the diagnostics overlay walk,
// both reached through OpenHarmonyWindowRenderer.Render, plus the recursive Describe log. The tree
// is kept detached so the assertion is independent of the app page the touch fuzz left behind.
var fuzzRenderer = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var fuzzTree = new VerticalStackLayout { Spacing = 1 };
Microsoft.Maui.ILayout fuzzCursor = fuzzTree;
for (int i = 0; i < 150; i++)
{
    var fuzzLabel = new Label { Text = $"fuzz node {i}", FontSize = 8 };
    var fuzzNested = new VerticalStackLayout { Spacing = 1 };
    fuzzCursor.Add(fuzzLabel);
    fuzzCursor.Add(fuzzNested);
    fuzzCursor = fuzzNested;
}
string fuzzTreeResult;
try
{
    OpenHarmonyDiagnostics.Enabled = true;
    bool fuzzRendered = fuzzRenderer.Render(fuzzTree, 1080, 1920);
    OpenHarmonyDiagnostics.Enabled = false;
    int fuzzNodes = OpenHarmonyAccessibility.Nodes.Count;
    int fuzzDescribeChars = fuzzRenderer.Describe(fuzzTree).Length;
    fuzzTreeResult = fuzzRendered && fuzzNodes >= 300 && fuzzDescribeChars > 0
        ? "render=True walk ok"
        : $"render={fuzzRendered} nodes={fuzzNodes} describeChars={fuzzDescribeChars}";
}
catch (Exception ex)
{
    OpenHarmonyDiagnostics.Enabled = false;
    fuzzTreeResult = $"{ex.GetType().Name}: {ex.Message}";
}
Console.WriteLine($"[verify] fuzz deep tree nodes=301 depth=150 seed=20260920 result={fuzzTreeResult}");
if (fuzzTreeResult != "render=True walk ok")
{
    throw new InvalidOperationException($"the deep-tree fuzz failed: {fuzzTreeResult}");
}

int fuzzMillis = (int)fuzzWatch.ElapsedMilliseconds;
Console.WriteLine($"[verify] fuzz bounded elapsed={fuzzMillis}ms limit=30000ms seed=20260920 (no hang)");
if (fuzzWatch.Elapsed > TimeSpan.FromSeconds(30))
{
    throw new InvalidOperationException($"the fuzz section took {fuzzMillis} ms");
}

// Target object for the HybridWebView JS -> .NET invocation checks. The reflection invoker
// matches methods by name and deserializes each JSON parameter value into the parameter type.
sealed class VerifyHybridInvokeTarget
{
    public string Echo(string value) => "echo:" + value;
    public int Add(int a, int b) => a + b;
}

sealed class ProbeDrawable : Microsoft.Maui.Graphics.IDrawable
{
    public int DrawCalls { get; private set; }
    public int TouchCalls { get; private set; }

    public void Draw(Microsoft.Maui.Graphics.ICanvas canvas, Microsoft.Maui.Graphics.RectF dirtyRect)
    {
        DrawCalls++;
        canvas.FillColor = Microsoft.Maui.Graphics.Colors.Magenta;
        canvas.FillRectangle(dirtyRect);
    }

    public void StartInteraction(Microsoft.Maui.Graphics.PointF[] points) => TouchCalls++;
    public void DragInteraction(Microsoft.Maui.Graphics.PointF[] points) { }
    public void EndInteraction(Microsoft.Maui.Graphics.PointF[] points, bool isInsideBounds) { }
}

static class gestures
{
    public static ProbeDrawable? Drawable;
    public static Microsoft.Maui.SwipeDirection LastSwipe;
    public static bool SwipeViewClicked;
    public static bool SwipeViewInvoked;
    public static int RefreshRuns;
    public static bool PointerEntered;
    public static bool PointerPressed;
    public static bool PointerReleased;
    public static bool PointerExited;
    public static string PinchLog = "";
    public static int TapCount;
    public static bool PanStarted;
    public static bool PanCompleted;
    public static double PanTotalY;
    public static int DragStartingCount;
    public static int DragOverCount;
    public static int DragLeaveCount;
    public static int DropCount;
    public static int DropCompletedCount;
    public static string? LastDragOverText;
    public static string? DroppedText;
    public static string LastDropResult = "?";

    public static string DropResultOf(Microsoft.Maui.Controls.DropCompletedEventArgs args)
    {
        // DropResult is internal in the Controls contract; read it reflectively in the harness.
        var prop = typeof(Microsoft.Maui.Controls.DropCompletedEventArgs).GetProperty("DropResult",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
        return prop?.GetValue(args)?.ToString() ?? "unknown";
    }
}

class RoutedPage : ContentPage
{
    public RoutedPage()
    {
        Title = "Routed";
        Content = new Label { Text = "routed page" };
    }
}

class TestApp : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new Window(new NavigationPage(BuildPage()) { Title = "Root", BarBackgroundColor = Colors.DarkSlateBlue });

    static ContentPage BuildPage()
    {
        var layout = new VerticalStackLayout { Padding = 24, Spacing = 16 };
        layout.Add(new Label { Text = "MAUI on OpenHarmony", FontSize = 40 });

        // Grid + HorizontalStackLayout exercise the layout handler.
        var grid = new Grid
        {
            ColumnDefinitions = { new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Auto) },
        };
        var horizontal = new HorizontalStackLayout { Spacing = 12 };
        horizontal.Add(new Label { Text = "grid:", FontSize = 28 });
        var gridButton = new Button { Text = "grid button" };
        gridButton.Clicked += (_, _) => Console.WriteLine("[verify] grid button clicked");
        horizontal.Add(gridButton);
        grid.Add(horizontal);
        layout.Add(grid);

        var button = new Button { Text = "Tap me" };
        button.Clicked += (_, _) => Console.WriteLine("[verify] Button.Clicked fired");
        layout.Add(button);
        layout.Add(new Entry { Placeholder = "type here", FontSize = 30 });

        var image = new Image { Source = ImageSource.FromFile(Path.Combine(Path.GetTempPath(), "verify-image.png")), HeightRequest = 120 };
        layout.Add(image);

        // W22-2: value controls (all drawn by the slice).
        var checkBox = new CheckBox { IsChecked = false };
        var toggle = new Switch { IsToggled = false };
        var slider = new Slider { Minimum = 0, Maximum = 100, Value = 50, HeightRequest = 40 };
        var progress = new ProgressBar { Progress = 0.25, HeightRequest = 8 };
        var spinner = new ActivityIndicator { IsRunning = true, HeightRequest = 24 };
        slider.DragCompleted += (_, _) => Console.WriteLine($"[verify] slider DragCompleted value={slider.Value:0.#}");
        checkBox.CheckedChanged += (_, e) => Console.WriteLine($"[verify] checkbox CheckedChanged={e.Value}");
        toggle.Toggled += (_, e) => Console.WriteLine($"[verify] switch Toggled={e.Value}");
        var controls = new HorizontalStackLayout { Spacing = 12 };
        controls.Add(checkBox);
        controls.Add(toggle);
        controls.Add(slider);
        layout.Add(controls);
        layout.Add(progress);
        layout.Add(spinner);

        // W22-7: animation, picker, tabbed page.
        var fadeLabel = new Label { Text = "fade me", FontSize = 28, Opacity = 1.0 };
        layout.Add(fadeLabel);
        var pickerCtl = new Picker { Title = "choose", FontSize = 26 };
        pickerCtl.Items.Add("alpha");
        pickerCtl.Items.Add("beta");
        pickerCtl.Items.Add("gamma");
        layout.Add(pickerCtl);

        // W22-13b: grid collection view (3 columns).
        var gridCollection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 9).Select(i => $"cell {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cellLabel = new Label { FontSize = 24 };
                cellLabel.SetBinding(Label.TextProperty, ".");
                return cellLabel;
            }),
            ItemsLayout = new GridItemsLayout(3, ItemsLayoutOrientation.Vertical),
            HeightRequest = 160,
        };
        layout.Add(gridCollection);

        // W22-15: grouped collection view (headers) + carousel looping.
        var grouped = new CollectionView
        {
            ItemsSource = new List<List<string>>
            {
                new() { "g1-item A", "g1-item B" },
                new() { "g2-item A", "g2-item B" },
            },
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 22 };
                itemLabel.SetBinding(Label.TextProperty, ".");
                return itemLabel;
            }),
            GroupHeaderTemplate = new DataTemplate(() =>
            {
                var header = new Label { FontSize = 24, TextColor = Colors.Gold };
                header.SetBinding(Label.TextProperty, ".");
                return header;
            }),
            IsGrouped = true,
            HeightRequest = 200,
        };
        layout.Add(grouped);

        // W22-12: legacy ListView (cells) + CarouselView.
        var listView = new ListView
        {
            ItemsSource = Enumerable.Range(0, 12).Select(i => $"list row {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cell = new TextCell();
                cell.SetBinding(TextCell.TextProperty, ".");
                return cell;
            }),
            HeightRequest = 200,
        };
        layout.Add(listView);

        var carousel = new CarouselView
        {
            ItemsSource = new List<string> { "slide A", "slide B", "slide C" },
            ItemTemplate = new DataTemplate(() =>
            {
                var label = new Label { FontSize = 34 };
                label.SetBinding(Label.TextProperty, ".");
                return label;
            }),
            HeightRequest = 140,
        };
        layout.Add(carousel);

        // Audit batch 2: GraphicsView / ContentView / ImageButton.
        layout.Add(new GraphicsView { Drawable = gestures.Drawable, HeightRequest = 80 });
        layout.Add(new ContentView
        {
            HeightRequest = 60,
            Content = new Label { Text = "content view", FontSize = 24 },
        });
        string buttonImagePath = Path.Combine(Path.GetTempPath(), "verify-button.png");
        File.WriteAllBytes(buttonImagePath, Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));
        layout.Add(new ImageButton { Source = ImageSource.FromFile(buttonImagePath), HeightRequest = 64 });

        // Audit batch: BoxView / IndicatorView / Frame / Editor (and a XAML page below).
        layout.Add(new BoxView { Color = Colors.Gold, HeightRequest = 18 });
        layout.Add(new IndicatorView { Count = 3, Position = 1, HeightRequest = 18 });
        layout.Add(new Frame
        {
            BorderColor = Colors.Teal,
            CornerRadius = 8,
            Content = new Label { Text = "framed", FontSize = 24 },
        });
        layout.Add(new Editor { Placeholder = "editor here", HeightRequest = 80 });

        // W22-9: async image source (stream).
        var streamImage = new Image { HeightRequest = 80 };
        streamImage.Source = ImageSource.FromStream(() => new MemoryStream(Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")));
        layout.Add(streamImage);

        // W22-8: date/time pickers.
        var datePicker = new DatePicker { Date = new DateTime(2026, 9, 17), FontSize = 26 };
        var timePicker = new TimePicker { Time = new TimeSpan(14, 30, 0), FontSize = 26 };
        layout.Add(new HorizontalStackLayout { Spacing = 16, Children = { datePicker, timePicker } });

        // Gap 1c: swipe gesture recognizer (reuses the drag tracking).
        var swipeLabel = new Label { Text = "swipe me", FontSize = 28 };
        var swipeGesture = new SwipeGestureRecognizer { Direction = SwipeDirection.Left | SwipeDirection.Right, Threshold = 30 };
        swipeGesture.Swiped += (_, e) => gestures.LastSwipe = e.Direction;
        swipeLabel.GestureRecognizers.Add(swipeGesture);
        layout.Insert(0, swipeLabel);

        // Limitations re-audit: pointer gestures (enter/press/release/exit).
        var pointerLabel = new Label { Text = "hover me", FontSize = 28 };
        var pointerGesture = new PointerGestureRecognizer();
        pointerGesture.PointerEntered += (_, _) => gestures.PointerEntered = true;
        pointerGesture.PointerPressed += (_, _) => gestures.PointerPressed = true;
        pointerGesture.PointerReleased += (_, _) => gestures.PointerReleased = true;
        pointerGesture.PointerExited += (_, _) => gestures.PointerExited = true;
        pointerLabel.GestureRecognizers.Add(pointerGesture);
        layout.Insert(1, pointerLabel);

        // Limitations re-audit: pinch gestures (shell reports phase/scale/centre).
        var pinchLabel = new Label { Text = "pinch me", FontSize = 28 };
        var pinchGesture = new PinchGestureRecognizer();
        pinchGesture.PinchUpdated += (_, e) => gestures.PinchLog += $"{e.Status}:{e.Scale:0.0} ";
        pinchLabel.GestureRecognizers.Add(pinchGesture);
        layout.Insert(2, pinchLabel);

        // Gap 1d: SwipeView with a right-hand item (revealed by a left drag).
        var swipeItem = new SwipeItem { Text = "Delete", BackgroundColor = Colors.OrangeRed };
        swipeItem.Clicked += (_, _) => gestures.SwipeViewClicked = true;
        swipeItem.Invoked += (_, _) => gestures.SwipeViewInvoked = true;
        var swipeRow = new SwipeView { HeightRequest = 120, Content = new Label { Text = "swipeable row" } };
        swipeRow.RightItems.Add(swipeItem);
        layout.Insert(1, swipeRow);

        // Gap 1d: RefreshView (pull down to refresh).
        var refreshView = new RefreshView { HeightRequest = 140, Content = new Label { Text = "pull to refresh" } };
        refreshView.Command = new Command(() => gestures.RefreshRuns++);
        layout.Insert(2, refreshView);

// W22-6: gestures + transforms.
        var tapLabel = new Label { Text = "tap me", FontSize = 28 };
        var tapGesture = new TapGestureRecognizer();
        tapGesture.Tapped += (_, _) => gestures.TapCount++;
        tapLabel.GestureRecognizers.Add(tapGesture);
        layout.Add(tapLabel);

        var panLabel = new Label { Text = "pan me", FontSize = 28 };
        var panGesture = new PanGestureRecognizer();
        panGesture.PanUpdated += (_, e) =>
        {
            if (e.StatusType == GestureStatus.Started) gestures.PanStarted = true;
            if (e.StatusType == GestureStatus.Running) gestures.PanTotalY = e.TotalY;
            if (e.StatusType == GestureStatus.Completed) gestures.PanCompleted = true;
        };
        panLabel.GestureRecognizers.Add(panGesture);
        layout.Add(panLabel);

        var animatedLabel = new Label { Text = "transformed", FontSize = 28, Opacity = 0.5, TranslationY = 12, Scale = 1.1, Rotation = 10 };
        layout.Add(animatedLabel);

        // W22-5: shapes, border, stepper, radio button, search bar.
        var shapes = new HorizontalStackLayout { Spacing = 12 };
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Rectangle { WidthRequest = 60, HeightRequest = 60, Fill = Colors.OrangeRed, Stroke = Colors.White, StrokeThickness = 2 });
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Ellipse { WidthRequest = 60, HeightRequest = 60, Fill = Colors.MediumSeaGreen });
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Line { X1 = 0, Y1 = 0, X2 = 60, Y2 = 60, Stroke = Colors.Gold, StrokeThickness = 3 });
        layout.Add(shapes);

        var border = new Border
        {
            Stroke = Colors.DodgerBlue,
            StrokeThickness = 3,
            Padding = 10,
            Content = new Label { Text = "inside border", FontSize = 26 },
        };
        layout.Add(border);

        var controls2 = new HorizontalStackLayout { Spacing = 16 };
        var stepper = new Stepper { Minimum = 0, Maximum = 10, Increment = 1, Value = 1 };
        var radio = new RadioButton { Content = "radio choice", IsChecked = false };
        var search = new SearchBar { Placeholder = "search...", HeightRequest = 48 };
        controls2.Add(stepper);
        controls2.Add(radio);
        controls2.Add(search);
        layout.Add(controls2);

        // W22-4: collection view with a template (items materialized by the slice).
        var collection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 20).Select(i => $"item {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 26 };
                itemLabel.SetBinding(Label.TextProperty, ".");
                return itemLabel;
            }),
            HeightRequest = 300,
            SelectionMode = SelectionMode.Single,
        };
        layout.Add(collection);

        // A scroll view with more content than fits.
        var tall = new VerticalStackLayout { Spacing = 8 };
        for (int i = 0; i < 12; i++)
        {
            tall.Add(new Label { Text = $"scroll row {i}", FontSize = 26 });
        }
        layout.Add(new ScrollView { Content = tall, HeightRequest = 400 });
        return new ContentPage { Content = layout };
    }
}
