// -----------------------------------------------------------------------------
// aac2wav.cs -- decode an MP4/AAC file to 48 kHz 16-bit stereo WAV using the
// Windows Media Foundation source reader (no ffmpeg on this machine).
//
//   csc /nologo /out:aac2wav.exe aac2wav.cs
//   aac2wav.exe <in.m4a> <out.wav> [maxSeconds]
//
// The interop is the standard trick: declare IMFSourceReader / IMFMediaType
// with their real base interfaces (IMFAttributes) so the vtable order matches.
// -----------------------------------------------------------------------------
using System;
using System.IO;
using System.Runtime.InteropServices;

static class Mf {
    public const int MF_SOURCE_READER_FIRST_AUDIO_STREAM = unchecked((int)0xFFFFFFFD);
    public const int MF_SOURCE_READER_ENABLE_AUDIO_PROCESSING = 0x00000008;

    public static readonly Guid MFMediaType_Audio = new Guid("73647561-0000-0010-8000-00AA00389B71");
    public static readonly Guid MFAudioFormat_PCM = new Guid("00000001-0000-0010-8000-00AA00389B71");
    public static readonly Guid MF_MT_MAJOR_TYPE = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MF_MT_SUBTYPE = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MF_MT_AUDIO_NUM_CHANNELS = new Guid("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid MF_MT_AUDIO_SAMPLES_PER_SECOND = new Guid("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid MF_MT_AUDIO_BITS_PER_SAMPLE = new Guid("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid MF_MT_ALL_SAMPLES_INDEPENDENT = new Guid("c9173739-5e56-461c-b713-46fb995cb95f");

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFStartup(int version, int flags);
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateMediaType(out IMFMediaType ppMFType);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int MFCreateSourceReaderFromURL(string pwszURL, IntPtr pAttributes, out IMFSourceReader ppSourceReader);
}

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFAttributes {
    int GetItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr pValue);
    int GetItemType([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pType);
    int CompareItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr Value, out bool pbResult);
    int Compare(IMFAttributes pTheirs, int MatchType, out bool pbResult);
    int GetUINT32([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int punValue);
    int GetUINT64([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out long punValue);
    int GetDouble([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out double pfValue);
    int GetGUID([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out Guid pguidValue);
    int GetStringLength([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pcchLength);
    int GetString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string pwszValue, int cchBufSize, out int pcchLength);
    int GetAllocatedString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out IntPtr ppwszValue, out int pcchLength);
    int GetBlobSize([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pcbBlobSize);
    int GetBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr pBuf, int cbBufSize, out int pcbBlobSize);
    int GetAllocatedBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out IntPtr ppBuf, out int pcbSize);
    int GetUnknown([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppv);
    int SetItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr Value);
    int DeleteItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey);
    int DeleteAllItems();
    int SetUINT32([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, int unValue);
    int SetUINT64([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, long unValue);
    int SetDouble([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, double fValue);
    int SetGUID([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPStruct)] Guid guidValue);
    int SetString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
    int SetBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, byte[] pBuf, int cbBufSize);
    int SetUnknown([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.IUnknown)] object pUnknown);
    int LockStore();
    int UnlockStore();
    int GetCount(out int pcItems);
    int GetItemByIndex(int unIndex, out Guid pguidKey, IntPtr pValue);
    int CopyAllItems(IMFAttributes pDest);
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae499155f5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaType : IMFAttributes {
    new int GetItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr pValue);
    new int GetItemType([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pType);
    new int CompareItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr Value, out bool pbResult);
    new int Compare(IMFAttributes pTheirs, int MatchType, out bool pbResult);
    new int GetUINT32([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int punValue);
    new int GetUINT64([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out long punValue);
    new int GetDouble([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out double pfValue);
    new int GetGUID([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out Guid pguidValue);
    new int GetStringLength([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pcchLength);
    new int GetString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string pwszValue, int cchBufSize, out int pcchLength);
    new int GetAllocatedString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out IntPtr ppwszValue, out int pcchLength);
    new int GetBlobSize([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out int pcbBlobSize);
    new int GetBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr pBuf, int cbBufSize, out int pcbBlobSize);
    new int GetAllocatedBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, out IntPtr ppBuf, out int pcbSize);
    new int GetUnknown([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppv);
    new int SetItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, IntPtr Value);
    new int DeleteItem([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey);
    new int DeleteAllItems();
    new int SetUINT32([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, int unValue);
    new int SetUINT64([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, long unValue);
    new int SetDouble([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, double fValue);
    new int SetGUID([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPStruct)] Guid guidValue);
    new int SetString([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
    new int SetBlob([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, byte[] pBuf, int cbBufSize);
    new int SetUnknown([MarshalAs(UnmanagedType.LPStruct)] Guid guidKey, [MarshalAs(UnmanagedType.IUnknown)] object pUnknown);
    new int LockStore();
    new int UnlockStore();
    new int GetCount(out int pcItems);
    new int GetItemByIndex(int unIndex, out Guid pguidKey, IntPtr pValue);
    new int CopyAllItems(IMFAttributes pDest);
    int GetMajorType(out Guid pguidMajorType);
    int IsCompressedFormat(out bool pfCompressed);
    int IsEqual(IMFMediaType pIMediaType, out int pdwFlags);
    int GetRepresentation(Guid guidRepresentation, out IntPtr ppvRepresentation);
    int FreeRepresentation(Guid guidRepresentation, IntPtr pvRepresentation);
}

[ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSourceReader {
    int GetStreamSelection(int dwStreamIndex, out bool pfSelected);
    int SetStreamSelection(int dwStreamIndex, bool fSelected);
    int GetNativeMediaType(int dwStreamIndex, int dwMediaTypeIndex, out IMFMediaType ppMediaType);
    int GetCurrentMediaType(int dwStreamIndex, out IMFMediaType ppMediaType);
    int SetCurrentMediaType(int dwStreamIndex, IntPtr pdwReserved, IMFMediaType pMediaType);
    int SetCurrentPosition([MarshalAs(UnmanagedType.LPStruct)] Guid guidTimeFormat, IntPtr varPosition);
    int ReadSample(int dwStreamIndex, int dwControlFlags, out int pdwActualStreamIndex,
                   out int pdwStreamFlags, out long pllTimestamp, out IMFSample ppSample);
    int Flush(int dwStreamIndex);
    int GetServiceForStream(int dwStreamIndex, [MarshalAs(UnmanagedType.LPStruct)] Guid guidService,
                            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppvObject);
    int GetPresentationAttribute(int dwStreamIndex, [MarshalAs(UnmanagedType.LPStruct)] Guid guidAttribute, IntPtr pvarAttribute);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSample {
    int GetSampleFlags(out int pdwSampleFlags);
    int SetSampleFlags(int dwSampleFlags);
    int GetSampleTime(out long phnsSampleTime);
    int SetSampleTime(long hnsSampleTime);
    int GetSampleDuration(out long phnsSampleDuration);
    int SetSampleDuration(long hnsSampleDuration);
    int GetBufferCount(out int pdwBufferCount);
    int GetBufferByIndex(int dwIndex, out IMFMediaBuffer ppBuffer);
    int ConvertToContiguousBuffer(out IMFMediaBuffer ppBuffer);
    int AddBuffer(IMFMediaBuffer pBuffer);
    int RemoveBufferByIndex(int dwIndex);
    int RemoveAllBuffers();
    int GetTotalLength(out int pcbTotalLength);
    int CopyToBuffer(IMFMediaBuffer pBuffer);
}

[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaBuffer {
    int Lock(out IntPtr ppbBuffer, out int pcbMaxLength, out int pcbCurrentLength);
    int Unlock();
    int GetCurrentLength(out int pcbCurrentLength);
    int SetCurrentLength(int cbCurrentLength);
    int GetMaxLength(out int pcbMaxLength);
}

static class Program {
    const int MF_SOURCE_READERF_ENDOFSTREAM = 0x00000002;

    static void WriteWavHeader(BinaryWriter w, int rate, short ch, short bits, int dataBytes) {
        w.Write(new char[] { 'R', 'I', 'F', 'F' });
        w.Write(36 + dataBytes);
        w.Write(new char[] { 'W', 'A', 'V', 'E' });
        w.Write(new char[] { 'f', 'm', 't', ' ' });
        w.Write(16);
        w.Write((short)1);
        w.Write(ch);
        w.Write(rate);
        w.Write(rate * ch * bits / 8);
        w.Write((short)(ch * bits / 8));
        w.Write(bits);
        w.Write(new char[] { 'd', 'a', 't', 'a' });
        w.Write(dataBytes);
    }

    static int Main(string[] args) {
        if (args.Length < 2) { Console.Error.WriteLine("usage: aac2wav <in> <out.wav> [maxSeconds]"); return 2; }
        string inPath = Path.GetFullPath(args[0]);
        string outPath = Path.GetFullPath(args[1]);
        double maxSec = args.Length > 2 ? double.Parse(args[2]) : 0;

        const int rate = 48000, ch = 2, bits = 16;

        int hr = Mf.MFStartup(0x00020070, 0);
        if (hr != 0) { Console.Error.WriteLine("MFStartup 0x" + hr.ToString("X8")); return 3; }

        IMFSourceReader reader = null;
        try {
            hr = Mf.MFCreateSourceReaderFromURL(inPath, IntPtr.Zero, out reader);
            if (hr != 0) { Console.Error.WriteLine("MFCreateSourceReaderFromURL 0x" + hr.ToString("X8")); return 4; }

            IMFMediaType mt;
            hr = Mf.MFCreateMediaType(out mt);
            if (hr != 0) { Console.Error.WriteLine("MFCreateMediaType 0x" + hr.ToString("X8")); return 5; }
            mt.SetGUID(Mf.MF_MT_MAJOR_TYPE, Mf.MFMediaType_Audio);
            mt.SetGUID(Mf.MF_MT_SUBTYPE, Mf.MFAudioFormat_PCM);
            mt.SetUINT32(Mf.MF_MT_AUDIO_NUM_CHANNELS, ch);
            mt.SetUINT32(Mf.MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
            mt.SetUINT32(Mf.MF_MT_AUDIO_BITS_PER_SAMPLE, bits);
            mt.SetUINT32(Mf.MF_MT_ALL_SAMPLES_INDEPENDENT, 1);

            hr = reader.SetCurrentMediaType(Mf.MF_SOURCE_READER_FIRST_AUDIO_STREAM, IntPtr.Zero, mt);
            if (hr != 0) { Console.Error.WriteLine("SetCurrentMediaType 0x" + hr.ToString("X8")); return 6; }

            // write into memory first (we do not know the byte count up front)
            var ms = new MemoryStream();
            long limit = maxSec > 0 ? (long)(maxSec * rate * ch * (bits / 8)) : long.MaxValue;
            int chunks = 0, bytes = 0;
            while (bytes < limit) {
                int idx, flags; long ts; IMFSample sample;
                hr = reader.ReadSample(Mf.MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, out idx, out flags, out ts, out sample);
                if (hr != 0) { Console.Error.WriteLine("ReadSample 0x" + hr.ToString("X8")); return 7; }
                if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) break;
                if (sample == null) continue;

                IMFMediaBuffer buf; int len;
                sample.ConvertToContiguousBuffer(out buf);
                buf.GetCurrentLength(out len);
                IntPtr p; int maxLen, curLen;
                buf.Lock(out p, out maxLen, out curLen);
                var tmp = new byte[curLen];
                Marshal.Copy(p, tmp, 0, curLen);
                buf.Unlock();
                Marshal.ReleaseComObject(buf);
                Marshal.ReleaseComObject(sample);

                int room = (int)Math.Min(curLen, limit - ms.Length);
                if (room <= 0) break;
                ms.Write(tmp, 0, room);
                bytes += room; chunks++;
            }

            byte[] data = ms.ToArray();
            using (var fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
            using (var w = new BinaryWriter(fs)) {
                WriteWavHeader(w, rate, (short)ch, (short)bits, data.Length);
                w.Write(data);
            }
            Console.WriteLine("ok: {0} chunks, {1} bytes PCM, {2:N1} s -> {3}",
                chunks, data.Length, data.Length / (double)(rate * ch * 2), outPath);
            return 0;
        } catch (Exception e) {
            Console.Error.WriteLine("exception: " + e);
            return 9;
        } finally {
            if (reader != null) Marshal.ReleaseComObject(reader);
            Mf.MFShutdown();
        }
    }
}
