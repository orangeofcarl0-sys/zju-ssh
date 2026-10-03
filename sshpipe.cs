// sshpipe.cs — Campus 便携 SSH 通道助手（无第三方依赖，init 时用 .NET Framework 自带 csc 编译）
// 用法: sshpipe auto|direct|socks <host> <port>
//   auto  : 先直连（800ms 超时，校园网场景，近零开销）；失败则走本地 SOCKS5（zju-connect
//           127.0.0.1:1080，校外场景）；SOCKS 未开则自动调用 campus-ssh.ps1 up 拉起并等待就绪。
//   direct: 仅直连。  socks: 仅 SOCKS5（不自动拉起）。
// 注意: stdout 是 ssh 的数据通道，一切诊断只写 stderr。
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

static class SshPipe {
    // 诊断日志开关：设置环境变量 Campus_SSHPIPE_DEBUG=1 时输出逐块调试信息，默认静默
    static bool Dbg { get { return Environment.GetEnvironmentVariable("Campus_SSHPIPE_DEBUG") == "1"; } }
    const int  DirectTimeoutMs = 800;
    const int  SocksPollMs     = 60000;
    const string SocksHost     = "127.0.0.1";
    const int    SocksPort     = 1080;

    static int Main(string[] args) {
        try {
            if (args.Length < 3) { Console.Error.WriteLine("usage: sshpipe auto|direct|socks <host> <port>"); return 2; }
            string mode = args[0].ToLowerInvariant();
            string host = args[1];
            int port = int.Parse(args[2]);
            TcpClient c;
            if (mode == "direct")      c = Direct(host, port);
            else if (mode == "socks")  c = Socks(host, port, false);
            else if (mode == "auto") {
                try { c = Direct(host, port); if (Dbg) Console.Error.WriteLine("sshpipe: campus-direct " + host + ":" + port); }
                catch { c = null; }
                if (c == null) c = Socks(host, port, true);
            }
            else { Console.Error.WriteLine("sshpipe: unknown mode " + mode); return 2; }
            Pipe(c);
            return 0;
        } catch (Exception e) {
            Console.Error.WriteLine("sshpipe: " + e.Message);
            return 1;
        }
    }

    static TcpClient Direct(string host, int port) {
        TcpClient c = new TcpClient();
        try {
            IAsyncResult ar = c.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(DirectTimeoutMs) || !c.Connected)
                throw new IOException("direct connect " + host + ":" + port + " failed");
            c.EndConnect(ar);
            return c;
        } catch {
            try { c.Close(); } catch {}
            throw;
        }
    }

    static bool SocksOpen() {
        try {
            TcpClient t = new TcpClient();
            IAsyncResult ar = t.BeginConnect(SocksHost, SocksPort, null, null);
            bool ok = ar.AsyncWaitHandle.WaitOne(400) && t.Connected;
            try { t.Close(); } catch {}
            return ok;
        } catch { return false; }
    }

    static void EnsureSocks(bool ensureRunning) {
        if (SocksOpen()) return;
        if (!ensureRunning) throw new IOException("SOCKS5 " + SocksHost + ":" + SocksPort + " 未运行（先执行: campus-ssh up）");
        string toolDir = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        string ps1 = Path.Combine(toolDir, "campus-ssh.ps1");
        if (!File.Exists(ps1)) throw new IOException("找不到 " + ps1);
        Console.Error.WriteLine("sshpipe: 当前为校外网络，正在启动 zju-connect 隧道（约需 10-30 秒，首次可能更久）...");
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\" up";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
        DateTime dl = DateTime.UtcNow.AddMilliseconds(SocksPollMs);
        while (DateTime.UtcNow < dl) {
            if (SocksOpen()) { if (Dbg) Console.Error.WriteLine("sshpipe: tunnel ready"); return; }
            Thread.Sleep(1000);
        }
        throw new IOException("等待 SOCKS5 超时：请运行 campus-ssh doctor，或查看 logs\\zju-err.log");
    }

    static TcpClient Socks(string host, int port, bool ensureRunning) {
        EnsureSocks(ensureRunning);
        TcpClient c = new TcpClient(SocksHost, SocksPort);
        NetworkStream s = c.GetStream();
        s.Write(new byte[] { 0x05, 0x01, 0x00 }, 0, 3);
        byte[] h = ReadExact(s, 2);
        if (h[0] != 0x05 || h[1] != 0x00) throw new IOException("SOCKS5 handshake failed");
        byte atyp; byte[] addr;
        IPAddress ip;
        if (IPAddress.TryParse(host, out ip) && ip.AddressFamily == AddressFamily.InterNetwork) {
            atyp = 0x01; addr = ip.GetAddressBytes();
        } else {
            atyp = 0x03; addr = Encoding.ASCII.GetBytes(host);
        }
        byte[] req;
        if (atyp == 0x01) {
            req = new byte[10];
            req[3] = 0x01; Array.Copy(addr, 0, req, 4, 4);
            req[8] = (byte)(port >> 8); req[9] = (byte)(port & 0xff);
        } else {
            req = new byte[7 + addr.Length];
            req[3] = 0x03; req[4] = (byte)addr.Length;
            Array.Copy(addr, 0, req, 5, addr.Length);
            int p = 5 + addr.Length;
            req[p] = (byte)(port >> 8); req[p + 1] = (byte)(port & 0xff);
        }
        s.Write(req, 0, req.Length);
        byte[] r = ReadExact(s, 4);
        if (r[1] != 0x00) throw new IOException("SOCKS5 connect rejected, code=" + r[1]);
        int skip = (r[3] == 0x01) ? 4 : (r[3] == 0x04) ? 16 : ReadExact(s, 1)[0];
        ReadExact(s, skip + 2);
        return c;
    }

    static byte[] ReadExact(Stream s, int n) {
        byte[] b = new byte[n]; int off = 0;
        while (off < n) {
            int k = s.Read(b, off, n - off);
            if (k <= 0) throw new IOException("stream short read");
            off += k;
        }
        return b;
    }

    static long lastActivity = 0;
    static bool stdinClosed = false;

    static void Touch() { lastActivity = DateTime.UtcNow.Ticks; }

    static void Pipe(TcpClient c) {
        Stream ns = c.GetStream();
        Stream sin = Console.OpenStandardInput(), sout = Console.OpenStandardOutput();
        Touch();
        Thread up = new Thread(delegate() {
            try {
                long n = CopyCount(sin, ns, "up");
                stdinClosed = true;
                if (Dbg) Console.Error.WriteLine("sshpipe: stdin closed after " + n + " bytes up");
            } catch (Exception e) {
                stdinClosed = true;
                Console.Error.WriteLine("sshpipe: stdin error: " + e.Message);
            }
        });
        Thread down = new Thread(delegate() {
            try {
                long n = CopyCount(ns, sout, "down");
                if (Dbg) Console.Error.WriteLine("sshpipe: remote closed after " + n + " bytes down");
            } catch (Exception e) {
                Console.Error.WriteLine("sshpipe: socket error: " + e.Message);
            }
            try { c.Close(); } catch {}
        });
        up.IsBackground = true; down.IsBackground = true;
        up.Start(); down.Start();
        // 看门狗：stdin 关闭且长时间无任何流量则退出（防 ssh 异常终止后的僵尸进程）
        while (down.IsAlive) {
            Thread.Sleep(2000);
            if (stdinClosed && (DateTime.UtcNow.Ticks - Interlocked.Read(ref lastActivity)) > 60000000L * 60) {
                Console.Error.WriteLine("sshpipe: idle watchdog exit");
                try { c.Close(); } catch {}
                Environment.Exit(0);
            }
        }
        try { c.Close(); } catch {}
    }

    static long CopyCount(Stream src, Stream dst, string dir) {
        byte[] buf = new byte[16384]; int n; long total = 0;
        while ((n = src.Read(buf, 0, buf.Length)) > 0) {
            dst.Write(buf, 0, n); dst.Flush();
            total += n; Touch();
            if (Dbg) Console.Error.WriteLine("sshpipe: " + dir + " chunk " + n + " (total " + total + ")");
        }
        return total;
    }
}
