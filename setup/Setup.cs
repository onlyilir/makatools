// Makatools-Setup.exe: installs, updates and uninstalls Makatools for the current Windows account.
// WPF, C# 5, built with the .NET Framework csc.exe that ships with Windows (build\Build.ps1). The app's
// files are gzip resources inside this exe ("payload/<path>.gz"). There is no self-extractor and nothing
// is unpacked to TEMP: Norton 360 deleted an IExpress installer that worked that way on another project.
//
//   Makatools-Setup.exe                 the window: install or update
//   Makatools-Setup.exe --update        same, but starts by itself and reopens Makatools when done
//   Makatools-Setup.exe --uninstall     the window: uninstall (the copy kept in the install folder)
//   --quiet                             no window; exit code 0 = done, 1 = failed (see the log)
//   --target <dir>                      another install folder (tests)
//   --snapshot <dir>                    developer check: every screen to PNG; changes nothing
// MK_TEST_LINK_DIR and MK_TEST_REG_KEY point shortcuts and the Apps entry elsewhere for tests.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

[assembly: AssemblyTitle("Makatools Setup")]
[assembly: AssemblyDescription("Installs Makatools for the current Windows account")]
[assembly: AssemblyProduct("Makatools")]
[assembly: AssemblyCompany("onlyilir")]
[assembly: AssemblyCopyright("Copyright (c) 2026 onlyilir. MIT License.")]
[assembly: AssemblyVersion("0.0.0.0")]        // replaced by build\Build.ps1
[assembly: AssemblyFileVersion("0.0.0.0")]    // replaced by build\Build.ps1

namespace MakatoolsSetup
{
    static class Program
    {
        public const string Version = "0.0.0";    // replaced by build\Build.ps1
        public const string SelfName = "Makatools-Setup.exe";

        [STAThread]
        static int Main(string[] args)
        {
            bool uninstall = args.Contains("--uninstall");
            bool quiet = args.Contains("--quiet");
            bool update = args.Contains("--update");
            string target = ArgValue(args, "--target") ?? Installer.DefaultTarget;
            string shots = ArgValue(args, "--snapshot");

            if (quiet)
                return Installer.Quiet(uninstall, target);

            var app = new Application();
            app.ShutdownMode = ShutdownMode.OnMainWindowClose;
            app.DispatcherUnhandledException += (s, e) =>
            {
                Installer.Log("Crash: " + e.Exception);
                MessageBox.Show("Makatools Setup hit a problem.\n\n" + e.Exception.Message, "Makatools Setup", MessageBoxButton.OK, MessageBoxImage.Error);
                e.Handled = true;
                app.Shutdown(1);
            };
            app.Resources = (ResourceDictionary)Load("Theme.xaml");
            app.Resources.MergedDictionaries.Add((ResourceDictionary)Load(IsDarkMode() ? "Colors.Dark.xaml" : "Colors.Light.xaml"));

            var ctl = new Controller(uninstall, update, target);
            if (shots != null)
            {
                ctl.Window.Loaded += async delegate { await ctl.Snapshots(shots); app.Shutdown(0); };
            }
            return app.Run(ctl.Window);
        }

        public static object Load(string name)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
                return XamlReader.Load(s);
        }

        static bool IsDarkMode()
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            {
                object v = k == null ? null : k.GetValue("AppsUseLightTheme");
                return v is int && (int)v == 0;
            }
        }

        static string ArgValue(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
    }

    static class Installer
    {
        public static string DefaultTarget
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Makatools"); }
        }

        static string UninstallKey
        {
            get { return Environment.GetEnvironmentVariable("MK_TEST_REG_KEY") ?? @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Makatools"; }
        }

        static string LinkDir(Environment.SpecialFolder real, string sub)
        {
            string test = Environment.GetEnvironmentVariable("MK_TEST_LINK_DIR");
            return string.IsNullOrEmpty(test) ? Environment.GetFolderPath(real) : Path.Combine(test, sub);
        }
        static string StartMenuLink { get { return Path.Combine(LinkDir(Environment.SpecialFolder.Programs, "start-menu"), "Makatools.lnk"); } }
        static string DesktopLink { get { return Path.Combine(LinkDir(Environment.SpecialFolder.DesktopDirectory, "desktop"), "Makatools.lnk"); } }

        public static string PowerShell
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"); }
        }

        public static string AppArguments(string target)
        {
            return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(target, "Makatools.ps1") + "\"";
        }

        public static void Log(string message)
        {
            try
            {
                File.AppendAllText(Path.Combine(Path.GetTempPath(), "Makatools-Setup.log"),
                                   DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + "\r\n");
            }
            catch (Exception) { }
        }

        public static bool IsInstalled(string target)
        {
            return File.Exists(Path.Combine(target, "Makatools.ps1"));
        }

        // Antivirus programs often hold a freshly written file open for a few seconds; retry before failing.
        static void Retry(Action a)
        {
            for (int i = 0; ; i++)
            {
                try
                {
                    a();
                    return;
                }
                catch (IOException)
                {
                    if (i >= 40)
                        throw;
                }
                catch (UnauthorizedAccessException)
                {
                    if (i >= 40)
                        throw;
                }
                Thread.Sleep(250);
            }
        }

        static bool SamePath(string a, string b)
        {
            return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }

        // Replaces the app's own files. Logs, Backups, Updates and the settings file are the user's and stay.
        public static void Install(string target)
        {
            Log("Install " + Program.Version + " to " + target);
            Assembly me = Assembly.GetExecutingAssembly();
            List<string> payload = me.GetManifestResourceNames().Where(n => n.StartsWith("payload/")).ToList();
            if (!payload.Contains("payload/Makatools.ps1.gz"))
                throw new FileNotFoundException("This setup file is incomplete. Download it again.");

            Directory.CreateDirectory(target);
            foreach (string folder in new[] { "src", "assets" })
            {
                string dir = Path.Combine(target, folder);
                if (Directory.Exists(dir))
                    Retry(() => Directory.Delete(dir, true));
            }
            // Left over from version 2.1 and earlier
            foreach (string old in new[] { "Uninstall.ps1", "Install Makatools.bat" })
            {
                string p = Path.Combine(target, old);
                if (File.Exists(p))
                    Retry(() => File.Delete(p));
            }
            foreach (string res in payload)
            {
                string rel = res.Substring("payload/".Length);
                rel = rel.Substring(0, rel.Length - ".gz".Length).Replace('/', '\\');
                string dst = Path.Combine(target, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                string name = res;
                Retry(() =>
                {
                    using (Stream s = me.GetManifestResourceStream(name))
                    using (var unzip = new GZipStream(s, CompressionMode.Decompress))
                    using (FileStream o = File.Create(dst))
                        unzip.CopyTo(o);
                });
            }
            // A copy of this exe stays behind as the uninstaller
            string keep = Path.Combine(target, Program.SelfName);
            if (!SamePath(me.Location, keep))
                Retry(() => File.Copy(me.Location, keep, true));

            string icon = Path.Combine(target, "assets", "Makatools.ico");
            Shortcut(StartMenuLink, target, icon);
            Shortcut(DesktopLink, target, icon);
            WriteUninstallEntry(target, icon);
            Log("Installed");
        }

        // Returns true when the folder itself still has to go after this process exits.
        public static bool Uninstall(string target)
        {
            Log("Uninstall from " + target);
            if (!IsInstalled(target))
                throw new FileNotFoundException("No Makatools install was found in " + target + ".");
            if (File.Exists(StartMenuLink))
                File.Delete(StartMenuLink);
            if (File.Exists(DesktopLink))
                File.Delete(DesktopLink);
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);

            string self = Assembly.GetExecutingAssembly().Location;
            bool runningFromTarget = SamePath(Path.GetDirectoryName(self), target);
            if (runningFromTarget)
            {
                // Everything but this exe now; the rest when it has exited
                foreach (string d in Directory.GetDirectories(target))
                {
                    string dir = d;
                    Retry(() => Directory.Delete(dir, true));
                }
                foreach (string f in Directory.GetFiles(target))
                {
                    if (SamePath(f, self))
                        continue;
                    string file = f;
                    Retry(() => File.Delete(file));
                }
                return true;
            }
            Retry(() => Directory.Delete(target, true));
            return false;
        }

        // Removes the install folder (and the running exe in it) a moment after we exit
        public static void DeleteFolderLater(string target)
        {
            try
            {
                Process.Start(new ProcessStartInfo("cmd.exe", "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + target.TrimEnd('\\') + "\"")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WorkingDirectory = Path.GetTempPath()
                });
            }
            catch (Exception) { }
        }

        static void Shortcut(string link, string target, string icon)
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            dynamic shell = Activator.CreateInstance(t);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(link));
                dynamic lnk = shell.CreateShortcut(link);
                lnk.TargetPath = PowerShell;
                lnk.Arguments = AppArguments(target);
                lnk.WorkingDirectory = target;
                lnk.IconLocation = icon + ",0";
                lnk.Description = "Free tools to clean up, speed up and look after your PC";
                lnk.Save();
                Marshal.FinalReleaseComObject(lnk);
            }
            finally
            {
                Marshal.FinalReleaseComObject(shell);
            }
        }

        static void WriteUninstallEntry(string target, string icon)
        {
            string self = Path.Combine(target, Program.SelfName);
            long kb = new DirectoryInfo(target).GetFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) / 1024;
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                k.SetValue("DisplayName", "Makatools");
                k.SetValue("DisplayVersion", Program.Version);
                k.SetValue("Publisher", "onlyilir");
                k.SetValue("DisplayIcon", icon);
                k.SetValue("InstallLocation", target);
                k.SetValue("UninstallString", "\"" + self + "\" --uninstall");
                k.SetValue("QuietUninstallString", "\"" + self + "\" --uninstall --quiet");
                k.SetValue("URLInfoAbout", "https://github.com/onlyilir/makatools");
                k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
                k.SetValue("EstimatedSize", (int)kb, RegistryValueKind.DWord);
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }

        public static int Quiet(bool uninstall, string target)
        {
            try
            {
                if (!uninstall)
                    Install(target);
                else if (Uninstall(target))
                    DeleteFolderLater(target);
                return 0;
            }
            catch (Exception ex)
            {
                Log("FAILED: " + ex);
                return 1;
            }
        }
    }

    class Controller
    {
        public readonly Window Window;
        readonly bool uninstall, autoUpdate, updating;
        readonly string target;
        bool deleteLater;

        T Find<T>(string name) where T : class { return (T)Window.FindName(name); }
        void Show(string name, bool on) { Find<FrameworkElement>(name).Visibility = on ? Visibility.Visible : Visibility.Collapsed; }

        public Controller(bool uninstall, bool autoUpdate, string target)
        {
            this.uninstall = uninstall;
            this.autoUpdate = autoUpdate;
            this.target = target;
            updating = !uninstall && Installer.IsInstalled(target);
            Window = (Window)Program.Load("SetupWindow.xaml");

            var logo = new BitmapImage();
            logo.BeginInit();
            logo.CacheOption = BitmapCacheOption.OnLoad;
            logo.StreamSource = Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.png");
            logo.EndInit();
            Find<Image>("Logo").Source = logo;

            Find<Button>("CloseX").Click += delegate { Window.Close(); };
            Find<Button>("DoneButton").Click += delegate { Window.Close(); };
            Find<Button>("OpenButton").Click += delegate { OpenApp(); Window.Close(); };
            Find<Button>("GoButton").Click += delegate { Go(); };
            Window.Closed += delegate { if (deleteLater) Installer.DeleteFolderLater(target); };

            Find<TextBlock>("HeadSub").Text = "Version " + Program.Version;
            if (uninstall)
            {
                Window.Title = "Uninstall Makatools";
                Find<TextBlock>("HeadTitle").Text = "Uninstall Makatools";
                Find<TextBlock>("BodyText").Text = "Removes the app, its shortcuts, its activity log and its settings from this PC.";
                var go = Find<Button>("GoButton");
                go.Content = "Uninstall";
                go.Style = (Style)Application.Current.Resources["Danger"];
                go.IsDefault = false;
            }
            else if (updating)
            {
                Find<TextBlock>("HeadTitle").Text = "Update Makatools";
                Find<TextBlock>("BodyText").Text = "Your settings and activity log are kept.";
                Find<Button>("GoButton").Content = "Update";
            }
            if (autoUpdate)
                Window.ContentRendered += delegate { Go(); };
        }

        void OpenApp()
        {
            try
            {
                Process.Start(new ProcessStartInfo(Installer.PowerShell, Installer.AppArguments(target))
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = target
                });
            }
            catch (Exception ex) { Installer.Log("Could not open the app: " + ex.Message); }
        }

        void ShowWorking()
        {
            Show("GoButton", false);
            Show("ErrorText", false);
            Show("WorkBar", true);
            Find<TextBlock>("BodyText").Text = uninstall ? "Removing files and shortcuts." : "Copying files and adding shortcuts.";
            Find<TextBlock>("HeadTitle").Text = uninstall ? "Uninstalling" : updating ? "Updating" : "Installing";
        }

        void ShowDone()
        {
            Show("WorkBar", false);
            Show("DoneBadge", true);
            if (uninstall)
            {
                Find<TextBlock>("HeadTitle").Text = "Makatools was removed";
                Find<TextBlock>("BodyText").Text = "Thanks for trying it.";
                Show("DoneButton", true);
            }
            else
            {
                Find<TextBlock>("HeadTitle").Text = updating ? "Makatools is up to date" : "Makatools is ready";
                Find<TextBlock>("BodyText").Text = "You'll find it on your Desktop and in the Start menu.";
                Show("OpenButton", true);
            }
        }

        async void Go()
        {
            ShowWorking();
            Exception error = null;
            DateTime started = DateTime.Now;
            await Task.Run(() =>
            {
                try
                {
                    if (uninstall)
                        deleteLater = Installer.Uninstall(target);
                    else
                        Installer.Install(target);
                }
                catch (Exception ex) { error = ex; }
            });
            // Long enough to read, however fast the copy was
            TimeSpan shown = DateTime.Now - started;
            if (shown < TimeSpan.FromMilliseconds(800))
                await Task.Delay(TimeSpan.FromMilliseconds(800) - shown);

            Show("WorkBar", false);
            if (error != null)
            {
                Installer.Log("FAILED: " + error);
                var err = Find<TextBlock>("ErrorText");
                err.Text = (error is IOException || error is UnauthorizedAccessException)
                    ? "A file is in use. Close Makatools and try again.\n" + error.Message
                    : error.Message;
                Show("ErrorText", true);
                Find<TextBlock>("HeadTitle").Text = "That didn't work";
                Find<TextBlock>("BodyText").Text = "Nothing important was changed.";
                Find<Button>("GoButton").Content = "Try Again";
                Show("GoButton", true);
                return;
            }
            ShowDone();
            if (autoUpdate)
            {
                await Task.Delay(700);
                OpenApp();
                Window.Close();
            }
        }

        // --snapshot: each screen as a PNG, installing nothing
        internal async System.Threading.Tasks.Task Snapshots(string dir)
        {
            Directory.CreateDirectory(dir);
            string prefix = uninstall ? "uninstall" : updating ? "update" : "install";
            await Task.Delay(300);
            Save(Path.Combine(dir, prefix + "-a-ready.png"));
            ShowWorking();
            await Task.Delay(300);
            Save(Path.Combine(dir, prefix + "-b-working.png"));
            ShowDone();
            await Task.Delay(300);
            Save(Path.Combine(dir, prefix + "-c-done.png"));
        }

        void Save(string path)
        {
            var root = (FrameworkElement)Window.Content;
            var bmp = new RenderTargetBitmap((int)root.ActualWidth, (int)root.ActualHeight, 96, 96, PixelFormats.Pbgra32);
            var dv = new DrawingVisual();
            using (DrawingContext dc = dv.RenderOpen())
            {
                var r = new Rect(0, 0, root.ActualWidth, root.ActualHeight);
                dc.DrawRectangle(Window.Background, null, r);
                dc.DrawRectangle(new VisualBrush(root), null, r);
            }
            bmp.Render(dv);
            var png = new PngBitmapEncoder();
            png.Frames.Add(BitmapFrame.Create(bmp));
            using (FileStream f = File.Create(path))
                png.Save(f);
        }
    }
}
