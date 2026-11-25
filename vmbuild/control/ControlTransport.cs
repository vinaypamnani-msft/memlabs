using System;
using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace MemLabs.Control {
    public static class Transport {
        private const int MaximumFrame = 262144;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr Descriptor;
            public int Inherit;
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
            string text, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr pointer);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafePipeHandle CreateNamedPipe(
            string name, uint mode, uint pipeMode, uint instances, uint outputSize,
            uint inputSize, uint timeout, ref SecurityAttributes attributes);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        internal static NamedPipeServerStream CreateServer(string name, string ownerSid) {
            new SecurityIdentifier(ownerSid);
            IntPtr descriptor;
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                    "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;" + ownerSid + ")", 1, out descriptor, out size)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                var attributes = new SecurityAttributes {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)), Descriptor = descriptor, Inherit = 0
                };
                // First-instance protection, overlapped I/O, and rejection of remote SMB pipe clients.
                SafePipeHandle handle = CreateNamedPipe(@"\\.\pipe\" + name, 0x40080003, 0x8, 1, 65536, 65536, 0, ref attributes);
                if (handle.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    handle.Dispose();
                    throw new Win32Exception(error);
                }
                try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
                catch { handle.Dispose(); throw; }
            }
            finally { LocalFree(descriptor); }
        }

        internal static string ReadFrame(Stream stream, int timeoutMilliseconds) {
            var header = new byte[4];
            stream.ReadExactlyAsync(header).AsTask().WaitAsync(TimeSpan.FromMilliseconds(timeoutMilliseconds)).GetAwaiter().GetResult();
            int length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
            if (length <= 0 || length > MaximumFrame) { throw new InvalidDataException("Control frame exceeds its permitted size."); }
            var body = new byte[length];
            stream.ReadExactlyAsync(body).AsTask().WaitAsync(TimeSpan.FromMilliseconds(timeoutMilliseconds)).GetAwaiter().GetResult();
            return Utf8.GetString(body);
        }

        internal static void WriteFrame(Stream stream, string text, int timeoutMilliseconds) {
            byte[] body = Utf8.GetBytes(text);
            if (body.Length == 0 || body.Length > MaximumFrame) { throw new InvalidDataException("Control response exceeds its permitted size."); }
            byte[] header = { (byte)(body.Length >> 24), (byte)(body.Length >> 16), (byte)(body.Length >> 8), (byte)body.Length };
            using (var cancellation = new CancellationTokenSource(timeoutMilliseconds)) {
                stream.WriteAsync(header, 0, header.Length, cancellation.Token).GetAwaiter().GetResult();
                stream.WriteAsync(body, 0, body.Length, cancellation.Token).GetAwaiter().GetResult();
                stream.FlushAsync(cancellation.Token).GetAwaiter().GetResult();
            }
        }

        public static string Exchange(string name, string request, int serverProcessId, long serverStartFileTime, string serverImage, int timeoutMilliseconds) {
            using (var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation)) {
                client.Connect(timeoutMilliseconds);
                uint observed;
                if (!GetNamedPipeServerProcessId(client.SafePipeHandle, out observed)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (observed != serverProcessId) { throw new UnauthorizedAccessException("Control pipe server does not match the protected runtime record."); }
                IntPtr process = OpenProcess(0x1000, false, observed);
                if (process == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                try {
                    long created, exited, kernel, user;
                    if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    var image = new StringBuilder(32768);
                    uint length = (uint)image.Capacity;
                    if (!QueryFullProcessImageName(process, 0, image, ref length)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    if (created != serverStartFileTime || !String.Equals(image.ToString(), serverImage, StringComparison.OrdinalIgnoreCase)) {
                        throw new UnauthorizedAccessException("Control pipe server identity changed.");
                    }
                }
                finally { CloseHandle(process); }
                WriteFrame(client, request, timeoutMilliseconds);
                return ReadFrame(client, timeoutMilliseconds);
            }
        }

        public static string ReadLine(TextReader reader) {
            var line = new StringBuilder();
            bool tooLong = false;
            while (true) {
                int character = reader.Read();
                if (character < 0) {
                    if (line.Length == 0 && !tooLong) { return null; }
                    break;
                }
                if (character == '\n') { break; }
                if (line.Length < 65536) { line.Append((char)character); }
                else { tooLong = true; }
            }
            if (tooLong) { throw new InvalidDataException("MCP input exceeds 64 KiB."); }
            return line.ToString().TrimEnd('\r');
        }

        public static string AddJsonEntry(string text, string mapName, string key, string entryJson) {
            byte[] bytes = Utf8.GetBytes(text);
            var options = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
            using (var document = JsonDocument.Parse(bytes, options)) {
                if (document.RootElement.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("MCP configuration must be a JSON object."); }
                JsonElement map;
                bool exists = document.RootElement.TryGetProperty(mapName, out map);
                if (exists && map.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("MCP server collection must be an object."); }
                JsonElement existing;
                if (exists && map.TryGetProperty(key, out existing)) { throw new InvalidOperationException("The MCP entry already exists; it must be compared before insertion."); }
                var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
                long rootStart = 0, rootLastValue = 0, mapStart = 0, mapLastValue = 0;
                bool nextMap = false, inMap = false;
                while (reader.Read()) {
                    if (reader.TokenType == JsonTokenType.StartObject && reader.CurrentDepth == 0) { rootStart = reader.BytesConsumed; }
                    if (reader.TokenType == JsonTokenType.PropertyName && reader.CurrentDepth == 1) { nextMap = reader.GetString() == mapName; }
                    else if (nextMap && reader.TokenType == JsonTokenType.StartObject && reader.CurrentDepth == 1) {
                        mapStart = reader.BytesConsumed; inMap = true; nextMap = false;
                    }
                    if (inMap && reader.CurrentDepth == 2 && reader.TokenType != JsonTokenType.PropertyName &&
                            reader.TokenType != JsonTokenType.StartObject && reader.TokenType != JsonTokenType.StartArray) {
                        mapLastValue = reader.BytesConsumed;
                    }
                    if (reader.TokenType == JsonTokenType.EndObject && reader.CurrentDepth == 1 && inMap) { inMap = false; }
                    if (reader.CurrentDepth == 1 && reader.TokenType != JsonTokenType.PropertyName &&
                            reader.TokenType != JsonTokenType.StartObject && reader.TokenType != JsonTokenType.StartArray) {
                        rootLastValue = reader.BytesConsumed;
                    }
                }
                string entry = JsonSerializer.Serialize(key) + ": " + entryJson;
                long offset;
                string insert;
                if (exists) {
                    offset = mapLastValue > 0 ? mapLastValue : mapStart;
                    insert = (mapLastValue > 0 ? "," : "") + "\n    " + entry + "\n";
                }
                else {
                    offset = rootLastValue > 0 ? rootLastValue : rootStart;
                    insert = (rootLastValue > 0 ? "," : "") + "\n  " + JsonSerializer.Serialize(mapName) + ": {\n    " + entry + "\n  }\n";
                }
                int position = Utf8.GetCharCount(bytes, 0, checked((int)offset));
                string result = text.Insert(position, insert);
                using (JsonDocument.Parse(result, options)) { }
                return result;
            }
        }
    }

    public sealed class Listener : IDisposable {
        private readonly NamedPipeServerStream pipe;
        private readonly Task accepting;
        private readonly string ownerSid;
        public uint ClientProcessId { get; private set; }
        public bool Ready { get { return accepting.IsCompleted; } }

        public Listener(string name, string ownerSid) {
            this.ownerSid = ownerSid;
            pipe = Transport.CreateServer(name, ownerSid);
            accepting = pipe.WaitForConnectionAsync();
        }
        public string ReadRequest() {
            accepting.GetAwaiter().GetResult();
            string observedSid = null;
            pipe.RunAsClient(delegate {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { observedSid = identity.User.Value; }
            });
            if (!String.Equals(observedSid, ownerSid, StringComparison.Ordinal)) { throw new UnauthorizedAccessException("This account is not authorized for the control endpoint."); }
            uint processId;
            if (!GetClientProcessId(pipe.SafePipeHandle, out processId)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            ClientProcessId = processId;
            return Transport.ReadFrame(pipe, 5000);
        }
        [DllImport("kernel32.dll", EntryPoint = "GetNamedPipeClientProcessId", SetLastError = true)]
        private static extern bool GetClientProcessId(SafePipeHandle handle, out uint processId);
        public void Respond(string response) { Transport.WriteFrame(pipe, response, 5000); }
        public void Dispose() {
            pipe.Dispose();
            if (accepting.IsFaulted) { GC.KeepAlive(accepting.Exception); }
        }
    }
}
