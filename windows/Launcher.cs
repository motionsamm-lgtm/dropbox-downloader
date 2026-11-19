using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("GOB")]
[assembly: AssemblyProduct("GOB — Grab Our Bytes")]
[assembly: AssemblyDescription("GOB download manager")]
[assembly: AssemblyVersion("1.1.3.0")]
[assembly: AssemblyFileVersion("1.1.3.0")]
class Launcher {
 [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
 static extern int SetCurrentProcessExplicitAppUserModelID(string id);
 [STAThread] static int Main(string[] args) {
  string root = AppDomain.CurrentDomain.BaseDirectory;
  try {
   SetCurrentProcessExplicitAppUserModelID("GOB.GrabOurBytes");
   string entry = "gui";
   string value = null;
   int guiPid = 0;
   bool smoke = false;
   if(args.Length > 0) {
    if(args[0] == "--self-test" && args.Length == 1) entry = "test";
    else if(args[0] == "--smoke-test" && args.Length == 1) smoke = true;
    else if(args[0] == "--worker" && args.Length == 2) { entry = "worker"; value = args[1]; }
    else if(args[0] == "--notify" && args.Length == 2) { entry = "notify"; value = args[1]; }
    else if(args[0] == "--update" && args.Length == 3 && (args[1] == "Check" || args[1] == "Install") && Int32.TryParse(args[2], out guiPid) && guiPid > 0) { entry = "update"; value = args[1]; }
    else throw new ArgumentException("Unsupported GOB startup arguments.");
   }
   Application.EnableVisualStyles();
   // Windows PowerShell's installed engine provides the existing download logic.
   // No external powershell.exe, execution-policy changes, or arbitrary script arguments.
   using(var runspace = RunspaceFactory.CreateRunspace()) {
    runspace.ApartmentState = ApartmentState.STA;
    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
    runspace.Open();
    runspace.SessionStateProxy.SetVariable("GOBRoot", root);
    runspace.SessionStateProxy.SetVariable("GOBExecutable", Assembly.GetExecutingAssembly().Location);
    runspace.SessionStateProxy.SetVariable("GobSmokeTest", smoke);
    runspace.SessionStateProxy.SetVariable("GobExitCode", 0);
    using(var ps = PowerShell.Create()) {
     ps.Runspace = runspace;
     string source;
     using(var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(entry + ".ps1")) {
      if(stream == null) throw new Exception("GOB component is missing: " + entry);
      using(var reader = new StreamReader(stream)) source = reader.ReadToEnd();
     }
     ps.AddScript(source);
     if(entry == "worker") ps.AddParameter("HistoryAttempt", value);
     if(entry == "notify") ps.AddParameter("Data", value);
     if(entry == "update") { ps.AddParameter("Mode", value); ps.AddParameter("GuiPid", guiPid); }
     ps.Invoke();
     if(ps.InvocationStateInfo.State == PSInvocationState.Failed) {
      var details = String.Join(Environment.NewLine, System.Linq.Enumerable.Select(ps.Streams.Error, e => e.ToString()));
      throw new Exception(details);
     }
     return Convert.ToInt32(runspace.SessionStateProxy.GetVariable("GobExitCode"));
    }
   }
  } catch(Exception e) {
   try {
    string logs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GOB");
    Directory.CreateDirectory(logs);
    File.AppendAllText(Path.Combine(logs,"startup.log.txt"), DateTime.Now.ToString("o") + " " + e.ToString() + Environment.NewLine);
   } catch {}
   if(args.Length == 0) MessageBox.Show(e.Message,"GOB could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
   return 1;
  }
 }
}
