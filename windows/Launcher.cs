using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("GOB")]
[assembly: AssemblyProduct("GOB — Grab Our Bytes")]
[assembly: AssemblyDescription("GOB download manager")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
class Launcher {
 [STAThread] static int Main(string[] args) {
  try {
   string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DropboxDownloader", "App-GOB-1.0.0");
   using(var mutex = new Mutex(false, "Local\\DropboxDownloaderExtractGOB100")) {
    bool held = false;
    try {
     try { held = mutex.WaitOne(TimeSpan.FromSeconds(30)); } catch(AbandonedMutexException) { held = true; }
     if(!held) throw new Exception("Another app launch is still extracting files. Try again.");
     if(!File.Exists(Path.Combine(root,"complete"))) {
      if(Directory.Exists(root)) Directory.Delete(root,true);
      Directory.CreateDirectory(root);
      using(var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload"))
      using(var zip = new ZipArchive(stream)) zip.ExtractToDirectory(root);
      File.WriteAllText(Path.Combine(root,"complete"),"1.0.0");
     }
    } finally { if(held) mutex.ReleaseMutex(); }
   }
   string install = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GOB");
   Directory.CreateDirectory(install);
   string installed = Path.Combine(install, "GOB.exe");
   string running = Assembly.GetExecutingAssembly().Location;
   if(!String.Equals(installed,running,StringComparison.OrdinalIgnoreCase)) File.Copy(running,installed,true);
   string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe");
   if(args.Length == 1 && args[0] == "--self-test") return File.Exists(Path.Combine(root,"aria2c.exe")) ? 0 : 1;
   var start = new ProcessStartInfo(ps, "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \""+Path.Combine(root,"Dropbox-Downloader-GUI.ps1")+"\"");
   start.UseShellExecute=false; start.CreateNoWindow=true;
   Process.Start(start).Dispose(); return 0;
  } catch(Exception e) { MessageBox.Show(e.Message,"GOB could not start"); return 1; }
 }
}
