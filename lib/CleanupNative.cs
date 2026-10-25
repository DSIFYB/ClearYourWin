using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ClearYourWin {
    public sealed class CleanupFile {
        public string Path { get; set; }
        public long Length { get; set; }
        public string FileId { get; set; }
        public string LastWriteTicks { get; set; }
        public string CreationTicks { get; set; }
    }

    // Deletes through a verified handle, never through a later path lookup.
    public static class CleanupNative {
        const uint ReadAttributes = 0x80, DeleteAccess = 0x10000;
        const uint ShareRead = 1, ShareWrite = 2, OpenExisting = 3;
        const uint OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
        const uint DirectoryAttribute = 0x10, ReparseAttribute = 0x400;

        [StructLayout(LayoutKind.Sequential)]
        struct FileTime { public uint Low; public uint High; }
        [StructLayout(LayoutKind.Sequential)]
        struct HandleInfo {
            public uint Attributes; public FileTime Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool Delete; }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle file, out HandleInfo info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass,
            ref Disposition info, uint size);

        static string Normalize(string path) {
            if (String.IsNullOrWhiteSpace(path) || path.Length < 3 ||
                !Char.IsLetter(path[0]) || path[1] != ':' || path[2] != '\\' ||
                path.IndexOf(':', 2) >= 0) throw new IOException("Only absolute local paths without streams are allowed.");
            string full = System.IO.Path.GetFullPath(path).TrimEnd('\\');
            foreach (string part in full.Substring(3).Split('\\')) {
                if (part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal))
                    throw new IOException("Ambiguous Windows path.");
            }
            return full;
        }
        static SafeFileHandle Open(string path, bool directory, bool deleting) {
            SafeFileHandle handle = CreateFile(path, ReadAttributes | (deleting ? DeleteAccess : 0),
                directory ? ShareRead | ShareWrite : ShareRead, IntPtr.Zero, OpenExisting,
                OpenReparse | (directory ? BackupSemantics : 0), IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            return handle;
        }
        static HandleInfo Info(SafeFileHandle handle, bool directory) {
            HandleInfo info;
            if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & ReparseAttribute) != 0 || ((info.Attributes & DirectoryAttribute) != 0) != directory)
                throw new IOException("Reparse points and unexpected file types are refused.");
            return info;
        }
        static void VerifyFinalPath(SafeFileHandle handle, string expected) {
            StringBuilder final = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, final, (uint)final.Capacity, 0);
            if (length == 0 || length >= final.Capacity) throw new IOException("Cannot verify final file path.");
            string actual = final.ToString();
            if (actual.StartsWith("\\\\?\\", StringComparison.Ordinal)) actual = actual.Substring(4);
            if (!String.Equals(actual.TrimEnd('\\'), expected.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Resolved path differs from the approved path.");
        }
        static long Ticks(FileTime time) {
            return DateTime.FromFileTimeUtc((long)(((ulong)time.High << 32) | time.Low)).Ticks;
        }
        static CleanupFile Describe(string path, HandleInfo info) {
            return new CleanupFile { Path = path, Length = checked((long)(((ulong)info.SizeHigh << 32) | info.SizeLow)),
                FileId = info.Volume.ToString("X8") + ":" + info.IndexHigh.ToString("X8") + info.IndexLow.ToString("X8"),
                LastWriteTicks = Ticks(info.Write).ToString(System.Globalization.CultureInfo.InvariantCulture),
                CreationTicks = Ticks(info.Creation).ToString(System.Globalization.CultureInfo.InvariantCulture) };
        }
        static CleanupFile Access(string root, string path, CleanupFile expected, long cutoffTicks, bool deleting) {
            root = Normalize(root); path = Normalize(path);
            if (root.Length <= 3 || !path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("File is outside the approved TEMP root.");
            List<SafeFileHandle> pins = new List<SafeFileHandle>();
            try {
                // Pin every directory from the volume root down, without delete sharing.
                string current = System.IO.Path.GetPathRoot(path);
                string parent = System.IO.Path.GetDirectoryName(path);
                SafeFileHandle pin = Open(current, true, false); pins.Add(pin); Info(pin, true); VerifyFinalPath(pin, current);
                foreach (string component in parent.Substring(current.Length).Split('\\')) {
                    if (component.Length == 0) continue;
                    current = System.IO.Path.Combine(current, component);
                    pin = Open(current, true, false); pins.Add(pin); Info(pin, true); VerifyFinalPath(pin, current);
                }
                using (SafeFileHandle file = Open(path, false, deleting)) {
                    HandleInfo info = Info(file, false);
                    VerifyFinalPath(file, path);
                    if (info.Links != 1 || (info.Attributes & (1u | 4u | 0x1000u)) != 0)
                        throw new IOException("Read-only, system, offline or multiply linked file skipped.");
                    CleanupFile actual = Describe(path, info);
                    if (Ticks(info.Write) >= cutoffTicks || Ticks(info.Creation) >= cutoffTicks)
                        throw new IOException("File is too recent for cleanup.");
                    if (expected != null && (actual.FileId != expected.FileId || actual.Length != expected.Length ||
                        actual.LastWriteTicks != expected.LastWriteTicks || actual.CreationTicks != expected.CreationTicks))
                        throw new IOException("File changed since the cleanup plan was created.");
                    if (deleting) {
                        Disposition disposition = new Disposition { Delete = true };
                        if (!SetFileInformationByHandle(file, 4, ref disposition, (uint)Marshal.SizeOf(typeof(Disposition))))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    return actual;
                }
            } finally { for (int i = pins.Count - 1; i >= 0; i--) pins[i].Dispose(); }
        }
        public static CleanupFile Inspect(string root, string path, long cutoffTicks) { return Access(root, path, null, cutoffTicks, false); }
        public static CleanupFile DeleteVerified(string root, CleanupFile expected, long cutoffTicks) {
            return Access(root, expected.Path, expected, cutoffTicks, true);
        }
    }
}
