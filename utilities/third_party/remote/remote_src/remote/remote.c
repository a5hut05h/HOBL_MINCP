#define _WIN32_WINNT 0x0A00
#include <rfb/rfb.h>
#include <rfb/keysym.h>
#include <windows.h>
#include <shellscalingapi.h>
#include <pathcch.h>
#include <d3d11.h>
#include <dxgi1_6.h>

#define MAX_MONS                16
#define IDM_DISP_BASE           1000
#define MAX_WAIT_TIME_MS        120000
#define RES_CHANGE_WAIT_TIME_MS 500

rfbScreenInfoPtr rfbScreen;

BOOL clientConnected = FALSE;

char savedWallpaperPath[MAX_PATH]  = {0};
char remoteWallpaperPath[MAX_PATH] = "wallpaper.png";

ID3D11Device* pDevice             = NULL;
ID3D11DeviceContext* pContext     = NULL;
IDXGIOutputDuplication* pDeskDupl = NULL;
ID3D11Texture2D* stagingTex       = NULL; // Persistent staging texture

HCURSOR lastCursor = NULL;
HCURSOR waitCursor = NULL;
volatile BOOL stopCursorThread = FALSE;
HANDLE hCursorThread = NULL;
int cursorWidth;
int cursorHeight;
int cursorStep = 0;

HDC gdiHScreenDC     = NULL;
HDC gdiHMemoryDC     = NULL;
BITMAPINFO gdiBmi    = {};

volatile BOOL ignoreClipboardUpdate = FALSE;

const RECT taskbarWndRect   = { 0, 0, 650, 0 };
const DWORD taskbarWndStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

static HRESULT gdiScreenCapture(int width, int height);
static HRESULT screenCapture(int width, int height);

typedef struct {
    // Selected display
    int32_t width;
    int32_t height;
    int32_t x;
    int32_t y;
    DWORD orientation;

    // Virtual display
    int32_t virtualWidth;
    int32_t virtualHeight;
    int32_t virtualX;
    int32_t virtualY;

    // Monitor info
    int32_t currentMonitor;
    HMONITOR hCurrentMonitor;
    int32_t numMonitors;
    WCHAR monitorNames[MAX_MONS][MAX_PATH];

    HRESULT (*screenCapture)(int, int);
} screenInfo;

screenInfo sInfo;

static float getSDRWhiteLevel()
{
    UINT32 pathCount = 0, modeCount = 0;
    GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount);

    DISPLAYCONFIG_PATH_INFO* paths = malloc(sizeof(*paths) * pathCount);
    DISPLAYCONFIG_MODE_INFO* modes = malloc(sizeof(*modes) * modeCount);

    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths,
                           &modeCount, modes, NULL) == ERROR_SUCCESS && pathCount > 0 && modeCount > 0)
    {
        DISPLAYCONFIG_SDR_WHITE_LEVEL wl = {0};

        // Assume primary path
        wl.header.type      = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
        wl.header.size      = sizeof(wl);
        wl.header.adapterId = paths[0].targetInfo.adapterId;
        wl.header.id        = paths[0].targetInfo.id;

        if (DisplayConfigGetDeviceInfo(&wl.header) == ERROR_SUCCESS)
        {
            return (float)(wl.SDRWhiteLevel / 1000);
        }
    }

    free(paths);
    free(modes);

    return 1.0;
}

static void getScreenInfo()
{
    DEVMODE dm = {0};
    dm.dmSize  = sizeof(dm);

    if (EnumDisplaySettings(NULL, ENUM_CURRENT_SETTINGS, &dm))
    {
        sInfo.orientation = dm.dmDisplayOrientation;

        sInfo.width  = dm.dmPelsWidth;
        sInfo.height = dm.dmPelsHeight;
    }
    else
    {
        sInfo.orientation = DMDO_DEFAULT;

        sInfo.width  = GetSystemMetrics(SM_CXSCREEN);
        sInfo.height = GetSystemMetrics(SM_CYSCREEN);
    }
}

static DWORD dxgiRotToDisplayOrient(DXGI_MODE_ROTATION rot)
{
    switch (rot)
    {
        case DXGI_MODE_ROTATION_UNSPECIFIED:
        case DXGI_MODE_ROTATION_IDENTITY:
            return DMDO_DEFAULT;
        case DXGI_MODE_ROTATION_ROTATE90:
            return DMDO_90;
        case DXGI_MODE_ROTATION_ROTATE180:
            return DMDO_180;
        case DXGI_MODE_ROTATION_ROTATE270:
            return DMDO_270;
        default:
            return DMDO_DEFAULT;
    }
}

static void getMonitorInfo(IDXGIAdapter1* pAdapter)
{
    BOOL found          = FALSE;
    UINT currentMonitor = 0;

    IDXGIOutput* pOutput = NULL;

    while (currentMonitor < MAX_MONS &&
           SUCCEEDED(pAdapter->lpVtbl->EnumOutputs(pAdapter, currentMonitor, &pOutput)))
    {
        DXGI_OUTPUT_DESC desc;
        pOutput->lpVtbl->GetDesc(pOutput, &desc);

        DISPLAY_DEVICEW dd;
        dd.cb = sizeof(dd);

        if (EnumDisplayDevicesW(desc.DeviceName, 0, &dd, 0))
        {
            rfbLog("Monitor %u: %ls\n", currentMonitor, dd.DeviceString);
            rfbLog("    DeviceName: %ls\n", desc.DeviceName);

            swprintf_s(
                sInfo.monitorNames[currentMonitor],
                MAX_PATH,
                L"%ls (%ls)",
                dd.DeviceString,
                desc.DeviceName
            );
        }
        else
        {
            rfbLog("Monitor %u: %ls (no friendly name found)\n", currentMonitor, desc.DeviceName);

            swprintf_s(
                sInfo.monitorNames[currentMonitor],
                MAX_PATH,
                desc.DeviceName
            );
        }

        RECT rect = desc.DesktopCoordinates;
        rfbLog("    Position: (%ld, %ld) to (%ld, %ld)\n", rect.left, rect.top, rect.right, rect.bottom);

        if (currentMonitor == sInfo.currentMonitor)
        {
            sInfo.hCurrentMonitor = desc.Monitor;

            sInfo.orientation = dxgiRotToDisplayOrient(desc.Rotation);

            sInfo.width  = rect.right - rect.left;
            sInfo.height = rect.bottom - rect.top;

            sInfo.x = rect.left;
            sInfo.y = rect.top;

            found = TRUE;

            rfbLog("    Using this monitor\n");
        }

        pOutput->lpVtbl->Release(pOutput);
        currentMonitor++;
    }

    sInfo.numMonitors = currentMonitor;

    if (!found)
    {
        rfbLog("No matching monitor found\n");
        sInfo.currentMonitor = 0;
        getScreenInfo();
    }

    sInfo.virtualX      = GetSystemMetrics(SM_XVIRTUALSCREEN);
    sInfo.virtualY      = GetSystemMetrics(SM_YVIRTUALSCREEN);
    sInfo.virtualWidth  = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    sInfo.virtualHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
}

static HRESULT gdiInitScreenCapture()
{
    MONITORINFOEX monitorInfo;
    monitorInfo.cbSize = sizeof(MONITORINFOEX);
    GetMonitorInfo(sInfo.hCurrentMonitor, (MONITORINFO*)&monitorInfo);

    gdiHScreenDC = CreateDC("DISPLAY", monitorInfo.szDevice, NULL, NULL);

    if (!gdiHScreenDC)
        return E_FAIL;

    gdiHMemoryDC = CreateCompatibleDC(gdiHScreenDC);

    if (!gdiHMemoryDC)
    {
        DeleteDC(gdiHScreenDC);
        gdiHScreenDC = NULL;
        return E_FAIL;
    }

    ZeroMemory(&gdiBmi, sizeof(gdiBmi));
    gdiBmi.bmiHeader.biSize        = sizeof(BITMAPINFOHEADER);
    gdiBmi.bmiHeader.biPlanes      = 1;
    gdiBmi.bmiHeader.biBitCount    = 32;
    gdiBmi.bmiHeader.biCompression = BI_RGB;

    return S_OK;
}

static HRESULT initScreenCapture()
{
    HRESULT hr;
    D3D_FEATURE_LEVEL featureLevel;

    IDXGIDevice* dxgiDevice    = NULL;
    IDXGIAdapter1* dxgiAdapter = NULL;
    IDXGIOutput* dxgiOutput    = NULL;
    IDXGIOutput6* dxgiOutput6  = NULL;

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                           0, NULL, 0, D3D11_SDK_VERSION,
                           &pDevice, &featureLevel, &pContext);

    if (FAILED(hr))
        return hr;

    hr = pDevice->lpVtbl->QueryInterface(pDevice, &IID_IDXGIDevice, (void**)&dxgiDevice);

    if (FAILED(hr))
        return hr;

    hr = dxgiDevice->lpVtbl->GetParent(dxgiDevice, &IID_IDXGIAdapter1, (void**)&dxgiAdapter);
    dxgiDevice->lpVtbl->Release(dxgiDevice);

    if (FAILED(hr))
        return hr;

    getMonitorInfo(dxgiAdapter);

    hr = dxgiAdapter->lpVtbl->EnumOutputs(dxgiAdapter, sInfo.currentMonitor, &dxgiOutput);
    dxgiAdapter->lpVtbl->Release(dxgiAdapter);

    if (FAILED(hr))
        return hr;

    hr = dxgiOutput->lpVtbl->QueryInterface(dxgiOutput, &IID_IDXGIOutput6, (void**)&dxgiOutput6);
    dxgiOutput->lpVtbl->Release(dxgiOutput);

    if (FAILED(hr))
        return hr;

    DXGI_OUTPUT_DESC1 desc = {0};
    dxgiOutput6->lpVtbl->GetDesc1(dxgiOutput6, &desc);

    DXGI_FORMAT formats[2];
    UINT formatCount = 0;

    if (SUCCEEDED(hr) && desc.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709)
    {
        sInfo.screenCapture = screenCapture;
        rfbLog("Using standard screen capture\n");

        formats[0]  = DXGI_FORMAT_B8G8R8A8_UNORM;
        formatCount = 1;
    }
    else
    {
        if (FAILED(hr))
            rfbLog("Error determining color space\n");

        hr = gdiInitScreenCapture();

        if (FAILED(hr))
            return hr;

        sInfo.screenCapture = gdiScreenCapture;
        rfbLog("Using GDI screen capture\n");

        formats[0]  = DXGI_FORMAT_R16G16B16A16_FLOAT;
        formats[1]  = DXGI_FORMAT_B8G8R8A8_UNORM;
        formatCount = 2;
    }

    hr = dxgiOutput6->lpVtbl->DuplicateOutput1(dxgiOutput6, (IUnknown*)pDevice, 0, formatCount, formats, &pDeskDupl);
    dxgiOutput6->lpVtbl->Release(dxgiOutput6);

    return hr;
}

static void cleanupScreenCapture()
{
    if (stagingTex)
    {
        stagingTex->lpVtbl->Release(stagingTex);
        stagingTex = NULL;
    }

    if (pDeskDupl)
    {
        pDeskDupl->lpVtbl->Release(pDeskDupl);
        pDeskDupl = NULL;
    }

    if (pContext)
    {
        pContext->lpVtbl->Release(pContext);
        pContext = NULL;
    }

    if (pDevice)
    {
        pDevice->lpVtbl->Release(pDevice);
        pDevice = NULL;
    }

    if (gdiHMemoryDC)
    {
        DeleteDC(gdiHMemoryDC);
        gdiHMemoryDC = NULL;
    }

    if (gdiHScreenDC)
    {
        DeleteDC(gdiHScreenDC);
        gdiHScreenDC = NULL;
    }
}

static void updateCursor()
{
    CURSORINFO cursorInfo = {0};
    cursorInfo.cbSize = sizeof(CURSORINFO);

    if (!(GetCursorInfo(&cursorInfo) && (cursorInfo.flags & CURSOR_SHOWING)))
        goto CLEANUP;

    if (cursorInfo.hCursor == lastCursor && lastCursor != waitCursor)
        goto CLEANUP;

    lastCursor = cursorInfo.hCursor;
    ICONINFO iconInfo = {0};

    if (!GetIconInfo(cursorInfo.hCursor, &iconInfo))
        goto CLEANUP;

    BITMAPINFO bmi;
    ZeroMemory(&bmi, sizeof(bmi));

    bmi.bmiHeader.biSize        = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth       = cursorWidth;
    bmi.bmiHeader.biHeight      = -cursorHeight; // top-down
    bmi.bmiHeader.biPlanes      = 1;
    bmi.bmiHeader.biBitCount    = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = NULL;

    HDC hdcScreen   = GetDC(NULL);
    HDC memDC       = CreateCompatibleDC(hdcScreen);
    HBITMAP hBitmap = CreateDIBSection(memDC, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);

    if (!(hBitmap && bits))
    {
        goto CLEANUP;
    }

    SelectObject(memDC, hBitmap);
    DrawIconEx(memDC, 0, 0, cursorInfo.hCursor, 0, 0, cursorStep, NULL, DI_NORMAL);
    cursorStep = (cursorStep + 1) % 18;

    rfbCursorPtr newCursor = (rfbCursorPtr)calloc(1, sizeof(*newCursor));

    newCursor->width     = cursorWidth;
    newCursor->height    = cursorHeight;
    newCursor->xhot      = (unsigned short)iconInfo.xHotspot;
    newCursor->yhot      = (unsigned short)iconInfo.yHotspot;
    newCursor->foreRed   = 0xFFFF;
    newCursor->foreGreen = 0xFFFF;
    newCursor->foreBlue  = 0xFFFF;
    newCursor->backRed   = 0;
    newCursor->backGreen = 0;
    newCursor->backBlue  = 0;
    newCursor->cleanup   = TRUE;

    int imageSize = cursorWidth * cursorHeight * 4;

    newCursor->richSource = (unsigned char*)malloc(imageSize);

    memcpy(newCursor->richSource, bits, imageSize);
    newCursor->cleanupRichSource = TRUE;

    // Create a 1-bit mask from the alpha channel
    int maskRowBytes = (cursorWidth + 7) / 8;
    int maskSize = maskRowBytes * cursorHeight;

    newCursor->mask = (unsigned char*)malloc(maskSize);

    memset(newCursor->mask, 0, maskSize);
    newCursor->cleanupMask = TRUE;

    for (int y = 0; y < cursorHeight; y++)
    {
        for (int x = 0; x < cursorWidth; x++)
        {
            // Assume the 4th byte is the alpha value
            unsigned char* pixel = newCursor->richSource + ((y * cursorWidth + x) * 4);
            unsigned char alpha  = pixel[3];

            if (alpha != 0)
            {
                int byteIndex = y * maskRowBytes + (x / 8);
                int bitPos    = x % 8;

                newCursor->mask[byteIndex] |= (0x80 >> bitPos);
            }
        }
    }

    rfbSetCursor(rfbScreen, newCursor);
    // Ensures cursor update occurs immediately
    rfbMarkRectAsModified(rfbScreen, 0, 0, 1, 1);

CLEANUP:
    if (hBitmap)
        DeleteObject(hBitmap);
    if (memDC)
        DeleteDC(memDC);
    if (hdcScreen)
        ReleaseDC(NULL, hdcScreen);

    if (iconInfo.hbmColor)
        DeleteObject(iconInfo.hbmColor);
    if (iconInfo.hbmMask)
        DeleteObject(iconInfo.hbmMask);
}

static DWORD WINAPI cursorHandler(LPVOID param)
{
    cursorWidth  = GetSystemMetrics(SM_CXCURSOR);
    cursorHeight = GetSystemMetrics(SM_CYCURSOR);

    waitCursor = LoadCursor(NULL, IDC_WAIT);

    while (!InterlockedCompareExchange(&stopCursorThread, FALSE, FALSE))
    {
        updateCursor();
        Sleep(50);
    }

    return 0;
}

static void startCursorThread()
{
    if (hCursorThread)
        return;

    InterlockedExchange(&stopCursorThread, FALSE);
    hCursorThread = CreateThread(NULL, 0, cursorHandler, NULL, 0, NULL);
}

static void stopCursorThreadAndWait()
{
    if (!hCursorThread)
        return;

    InterlockedExchange(&stopCursorThread, TRUE);

    THREAD_JOIN(hCursorThread);
    THREAD_DETACH(hCursorThread);
    hCursorThread = NULL;
}


static float halfToFloat(uint16_t h) {
    uint16_t h_exp = (h & 0x7C00);
    uint16_t h_sig = (h & 0x03FF);
    uint32_t f_sgn = (h & 0x8000) << 16;
    uint32_t f_exp, f_sig;

    if (h_exp == 0)
    {
        if (h_sig == 0)
        {
            f_exp = 0;
            f_sig = 0;
        }
        else
        {
            // Normalize subnormals
            int shift = 0;
            while ((h_sig & 0x0400) == 0)
            {
                h_sig <<= 1;
                shift++;
            }
            h_sig &= 0x03FF;
            f_exp = (127 - 15 - shift + 1) << 23;
            f_sig = h_sig << 13;
        }
    }
    else if (h_exp == 0x7C00)
    {
        // Infinity or NaN
        f_exp = 0xFF << 23;
        f_sig = h_sig << 13;
    }
    else
    {
        // Normalized value
        f_exp = ((h >> 10) & 0x1F) - 15 + 127;
        f_exp <<= 23;
        f_sig = h_sig << 13;
    }

    uint32_t f = f_sgn | f_exp | f_sig;
    float result;
    memcpy(&result, &f, sizeof(result));
    return result;
}

static inline uint8_t clamp(int v)
{
    return (v > 255) ? 255 : (v < 0 ? 0 : v);
}

static uint8_t convert16to8(uint16_t v)
{
    // Half-float -> 32-bit float
    float vF = halfToFloat(v);

    // Reinhard tone map
    vF = vF / (vF + 1.0f);

    // 8-bit conversion
    return clamp((int)(vF * 255.0f));
}

static void dirtyCopy(const uint8_t* src, int srcRowPitch, int width, int height, int nbytes, const RECT* rects, UINT numRects)
{
    for (UINT r = 0; r < numRects; r++)
    {
        switch (sInfo.orientation)
        {
            case DMDO_DEFAULT:
            {
                // Clamp and copy row‐by‐row
                RECT rect = rects[r];

                if (rect.left < 0)        rect.left   = 0;
                if (rect.top < 0)         rect.top    = 0;
                if (rect.right > width)   rect.right  = width;
                if (rect.bottom > height) rect.bottom = height;

                for (int y = rect.top; y < rect.bottom; y++)
                {
                    const uint8_t* srcRow = src + y * srcRowPitch + rect.left * nbytes;
                    uint8_t* dstRow       = rfbScreen->frameBuffer + y * width * nbytes + rect.left * nbytes;

                    memcpy(dstRow, srcRow, (rect.right - rect.left) * nbytes);
                }

                // Mark the dirty rect as modified
                rfbMarkRectAsModified(rfbScreen, rect.left, rect.top, rect.right, rect.bottom);
                break;
            }
            case DMDO_90:
            {
                int rawWidth  = height;
                int rawHeight = width;

                RECT rect = rects[r];

                if (rect.left < 0)           rect.left   = 0;
                if (rect.top < 0)            rect.top    = 0;
                if (rect.right > rawWidth)   rect.right  = rawWidth;
                if (rect.bottom > rawHeight) rect.bottom = rawHeight;

                for (int sy = rect.top; sy < rect.bottom; sy++)
                {
                    for (int sx = rect.left; sx < rect.right; sx++)
                    {
                        const uint8_t* srcPixel = src + sy * srcRowPitch + sx * nbytes;

                        uint32_t dx = rawHeight - 1 - sy;
                        uint32_t dy = sx;

                        uint8_t* dstPixel = rfbScreen->frameBuffer + (dy * width + dx) * nbytes;

                        memcpy(dstPixel, srcPixel, nbytes);
                    }
                }

                uint32_t destLeft   = rawHeight - rect.bottom;
                uint32_t destTop    = rect.left;
                uint32_t destRight  = rawHeight - rect.top;
                uint32_t destBottom = rect.right;

                rfbMarkRectAsModified(rfbScreen, destLeft, destTop, destRight, destBottom);
                break;
            }
            case DMDO_180:
            {
                int rawWidth  = width;
                int rawHeight = height;

                RECT rect = rects[r];

                if (rect.left < 0)           rect.left   = 0;
                if (rect.top < 0)            rect.top    = 0;
                if (rect.right > rawWidth)   rect.right  = rawWidth;
                if (rect.bottom > rawHeight) rect.bottom = rawHeight;

                for (int sy = rect.top; sy < rect.bottom; sy++)
                {
                    for (int sx = rect.left; sx < rect.right; sx++)
                    {
                        const uint8_t* srcPixel = src + sy * srcRowPitch + sx * nbytes;

                        uint32_t dx = rawWidth - 1 - sx;
                        uint32_t dy = rawHeight - 1 - sy;

                        uint8_t* dstPixel = rfbScreen->frameBuffer + (dy * rawWidth + dx) * nbytes;

                        memcpy(dstPixel, srcPixel, nbytes);
                    }
                }

                uint32_t destLeft   = rawWidth - rect.right;
                uint32_t destTop    = rawHeight - rect.bottom;
                uint32_t destRight  = rawWidth - rect.left;
                uint32_t destBottom = rawHeight - rect.top;

                rfbMarkRectAsModified(rfbScreen, destLeft, destTop, destRight, destBottom);
                break;
            }
            case DMDO_270:
            {
                int rawWidth  = height;
                int rawHeight = width;

                RECT rect = rects[r];

                if (rect.left < 0)           rect.left   = 0;
                if (rect.top < 0)            rect.top    = 0;
                if (rect.right > rawWidth)   rect.right  = rawWidth;
                if (rect.bottom > rawHeight) rect.bottom = rawHeight;

                for (int sy = rect.top; sy < rect.bottom; sy++)
                {
                    for (int sx = rect.left; sx < rect.right; sx++)
                    {
                        const uint8_t* srcPixel = src + sy * srcRowPitch + sx * nbytes;

                        uint32_t dx = sy;
                        uint32_t dy = rawWidth - 1 - sx;

                        uint8_t* dstPixel = rfbScreen->frameBuffer + (dy * width + dx) * nbytes;

                        memcpy(dstPixel, srcPixel, nbytes);
                    }
                }

                uint32_t destLeft   = rect.top;
                uint32_t destTop    = rawWidth - rect.right;
                uint32_t destRight  = rect.bottom;
                uint32_t destBottom = rawWidth - rect.left;

                rfbMarkRectAsModified(rfbScreen, destLeft, destTop, destRight, destBottom);
                break;
            }
        }
    }
}

static HRESULT gdiScreenCaptureHelper(int width, int height, int nbytes, const RECT* rects, UINT numRects)
{
    if (!gdiHScreenDC || !gdiHMemoryDC)
        return E_FAIL;

    for (UINT r = 0; r < numRects; r++)
    {
        RECT rect = rects[r];

        uint32_t destLeft;
        uint32_t destTop;
        uint32_t destRight;
        uint32_t destBottom;

        switch (sInfo.orientation)
        {
            case DMDO_DEFAULT:
            {
                if (rect.left < 0)        rect.left   = 0;
                if (rect.top < 0)         rect.top    = 0;
                if (rect.right > width)   rect.right  = width;
                if (rect.bottom > height) rect.bottom = height;

                destLeft   = rect.left;
                destTop    = rect.top;
                destRight  = rect.right;
                destBottom = rect.bottom;
                break;
            }
            case DMDO_90:
            {
                int rawWidth  = height;
                int rawHeight = width;

                if (rect.left < 0)           rect.left   = 0;
                if (rect.top < 0)            rect.top    = 0;
                if (rect.right > rawWidth)   rect.right  = rawWidth;
                if (rect.bottom > rawHeight) rect.bottom = rawHeight;

                destLeft   = rawHeight - rect.bottom;
                destTop    = rect.left;
                destRight  = rawHeight - rect.top;
                destBottom = rect.right;
                break;
            }
            case DMDO_180:
            {
                if (rect.left < 0)        rect.left   = 0;
                if (rect.top < 0)         rect.top    = 0;
                if (rect.right > width)   rect.right  = width;
                if (rect.bottom > height) rect.bottom = height;

                destLeft   = width - rect.right;
                destTop    = height - rect.bottom;
                destRight  = width - rect.left;
                destBottom = height - rect.top;
                break;
            }
            case DMDO_270:
            {
                int rawWidth  = height;
                int rawHeight = width;

                if (rect.left < 0)           rect.left   = 0;
                if (rect.top < 0)            rect.top    = 0;
                if (rect.right > rawWidth)   rect.right  = rawWidth;
                if (rect.bottom > rawHeight) rect.bottom = rawHeight;

                destLeft   = rect.top;
                destTop    = rawWidth - rect.right;
                destRight  = rect.bottom;
                destBottom = rawWidth - rect.left;
                break;
            }
        }

        int rw = destRight - destLeft;
        int rh = destBottom - destTop;

        BITMAPINFO bmi = gdiBmi;
        bmi.bmiHeader.biWidth  = rw;
        bmi.bmiHeader.biHeight = -rh; // top-down

        void* bits   = NULL;
        HBITMAP hDIB = CreateDIBSection(gdiHScreenDC, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);

        if (!(hDIB && bits))
            return E_FAIL;

        HGDIOBJ hOldBmp = SelectObject(gdiHMemoryDC, hDIB);

        if (!BitBlt(gdiHMemoryDC, 0, 0, rw, rh, gdiHScreenDC, destLeft, destTop, SRCCOPY))
        {
            SelectObject(gdiHMemoryDC, hOldBmp);
            DeleteObject(hDIB);
            return E_FAIL;
        }

        for (int y = 0; y < rh; y++)
        {
            uint8_t* src = (uint8_t*)bits + y * rw * nbytes;
            uint8_t* dst = rfbScreen->frameBuffer + ((destTop + y) * width + destLeft) * nbytes;
            memcpy(dst, src, rw * nbytes);
        }

        rfbMarkRectAsModified(rfbScreen, destLeft, destTop, destRight, destBottom);

        SelectObject(gdiHMemoryDC, hOldBmp);
        DeleteObject(hDIB);
    }

    return S_OK;
}

static HRESULT gdiScreenCapture(int width, int height)
{
    if (!pDeskDupl)
        return E_FAIL;

    IDXGIResource* desktopResource = NULL;

    DXGI_OUTDUPL_FRAME_INFO frameInfo;

    memset(&frameInfo, 0, sizeof(frameInfo));
    HRESULT hr = pDeskDupl->lpVtbl->AcquireNextFrame(pDeskDupl, 500, &frameInfo, &desktopResource);

    if (FAILED(hr))
    {
        // Treat timeout as ok as it simply means the screen
        // is not updating often
        return hr == DXGI_ERROR_WAIT_TIMEOUT ? S_OK : hr;
    }

    desktopResource->lpVtbl->Release(desktopResource);

    if (frameInfo.TotalMetadataBufferSize > 0)
    {
        UINT bufferSize  = frameInfo.TotalMetadataBufferSize;
        RECT* dirtyRects = (RECT*)malloc(bufferSize);

        hr = pDeskDupl->lpVtbl->GetFrameDirtyRects(pDeskDupl, bufferSize, dirtyRects, &bufferSize);

        if (SUCCEEDED(hr))
        {
            UINT numDirtyRects = bufferSize / sizeof(RECT);
            gdiScreenCaptureHelper(width, height, 4, dirtyRects, numDirtyRects);
        }

        free(dirtyRects);
    }

    pDeskDupl->lpVtbl->ReleaseFrame(pDeskDupl);

    return S_OK;
}

// Capture a frame using the Desktop Duplication API. This function acquires the latest frame,
// copies it into a persistent staging texture, maps that texture, and then copies the data row-by-row
// into a temporary buffer. It then composites the cursor using GDI onto the temporary buffer before
// computing dirty regions.
static HRESULT screenCapture(int width, int height)
{
    if (!pDeskDupl)
        return E_FAIL;

    IDXGIResource* desktopResource = NULL;
    ID3D11Texture2D* acquiredImage = NULL;

    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    D3D11_TEXTURE2D_DESC desc;
    D3D11_MAPPED_SUBRESOURCE mapped;

    memset(&frameInfo, 0, sizeof(frameInfo));
    HRESULT hr = pDeskDupl->lpVtbl->AcquireNextFrame(pDeskDupl, 500, &frameInfo, &desktopResource);

    if (FAILED(hr))
    {
        // Treat timeout as ok as it simply means the screen
        // is not updating often
        return hr == DXGI_ERROR_WAIT_TIMEOUT ? S_OK : hr;
    }

    hr = desktopResource->lpVtbl->QueryInterface(desktopResource, &IID_ID3D11Texture2D, (void**)&acquiredImage);
    desktopResource->lpVtbl->Release(desktopResource);

    if (FAILED(hr))
    {
        pDeskDupl->lpVtbl->ReleaseFrame(pDeskDupl);
        return hr;
    }

    acquiredImage->lpVtbl->GetDesc(acquiredImage, &desc);

    if (stagingTex == NULL || desc.Width != (UINT)width || desc.Height != (UINT)height)
    {
        if (stagingTex)
        {
            stagingTex->lpVtbl->Release(stagingTex);
            stagingTex = NULL;
        }

        // Set to 32-bit unsigned-normalized-integer format in case it is not
        // already, such as on a HDR display
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;

        desc.Usage          = D3D11_USAGE_STAGING;
        desc.BindFlags      = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ | D3D11_CPU_ACCESS_WRITE;
        desc.MiscFlags      = 0;

        hr = pDevice->lpVtbl->CreateTexture2D(pDevice, &desc, NULL, &stagingTex);

        if (FAILED(hr))
        {
            acquiredImage->lpVtbl->Release(acquiredImage);
            pDeskDupl->lpVtbl->ReleaseFrame(pDeskDupl);
            return hr;
        }
    }

    pContext->lpVtbl->CopyResource(pContext, (ID3D11Resource*)stagingTex, (ID3D11Resource*)acquiredImage);
    acquiredImage->lpVtbl->Release(acquiredImage);

    hr = pContext->lpVtbl->Map(pContext, (ID3D11Resource*)stagingTex, 0, D3D11_MAP_READ_WRITE, 0, &mapped);

    if (FAILED(hr))
    {
        pDeskDupl->lpVtbl->ReleaseFrame(pDeskDupl);
        return hr;
    }

    if (frameInfo.TotalMetadataBufferSize > 0)
    {
        UINT bufferSize  = frameInfo.TotalMetadataBufferSize;
        RECT* dirtyRects = (RECT*)malloc(bufferSize);

        if (dirtyRects)
        {
            hr = pDeskDupl->lpVtbl->GetFrameDirtyRects(pDeskDupl, bufferSize, dirtyRects, &bufferSize);

            if (SUCCEEDED(hr))
            {
                UINT numDirtyRects = bufferSize / sizeof(RECT);
                dirtyCopy((uint8_t*)mapped.pData, mapped.RowPitch, width, height, 4, dirtyRects, numDirtyRects);
            }

            free(dirtyRects);
        }
    }

    pContext->lpVtbl->Unmap(pContext, (ID3D11Resource*)stagingTex, 0);
    pDeskDupl->lpVtbl->ReleaseFrame(pDeskDupl);

    return S_OK;
}

static UINT keySymToVK(rfbKeySym keySym)
{
    // Printable ASCII range
    if (keySym >= XK_space && keySym <= XK_asciitilde)
    {
        SHORT vk = VkKeyScan((char)keySym);

        if (vk != -1)
            return LOBYTE(vk);
    }

    switch (keySym)
    {
        case XK_BackSpace: return VK_BACK;
        case XK_Tab:       return VK_TAB;
        case XK_Return:    return VK_RETURN;
        case XK_Escape:    return VK_ESCAPE;
        case XK_Delete:    return VK_DELETE;

        case XK_Caps_Lock: return VK_CAPITAL;
        case XK_Shift_L:   return VK_LSHIFT;
        case XK_Shift_R:   return VK_RSHIFT;
        case XK_Control_L: return VK_LCONTROL;
        case XK_Control_R: return VK_RCONTROL;
        case XK_Alt_L:     return VK_MENU;
        case XK_Alt_R:     return VK_MENU;
        case XK_Meta_L:    return VK_LWIN;
        case XK_Meta_R:    return VK_RWIN;

        // Navigation keys
        case XK_Home:      return VK_HOME;
        case XK_Left:      return VK_LEFT;
        case XK_Up:        return VK_UP;
        case XK_Right:     return VK_RIGHT;
        case XK_Down:      return VK_DOWN;
        case XK_Page_Up:   return VK_PRIOR;
        case XK_Page_Down: return VK_NEXT;
        case XK_End:       return VK_END;
        case XK_Insert:    return VK_INSERT;

        default:
            if (keySym >= XK_F1 && keySym <= XK_F12)
                return VK_F1 + (keySym - XK_F1);
    }

    return 0;
}

static void dokbd(rfbBool down, rfbKeySym keySym, rfbClientPtr cl)
{
    UINT vk = keySymToVK(keySym);

    if (vk == 0)
        return;

    INPUT input          = {0};
    input.type           = INPUT_KEYBOARD;
    input.ki.wVk         = vk;
    input.ki.dwExtraInfo = 0;
    input.ki.time        = 0;

    input.ki.wScan = (WORD)MapVirtualKey(vk, MAPVK_VK_TO_VSC);

    if (!down)
        input.ki.dwFlags |= KEYEVENTF_KEYUP;

    SendInput(1, &input, sizeof(INPUT));
}

static void doptr(int buttonMask, int x, int y, rfbClientPtr cl)
{
    static int oldButtonMask = 0;

    BOOL diff  = buttonMask != oldButtonMask;
    int change = buttonMask ^ oldButtonMask;

    oldButtonMask = buttonMask;

    INPUT inputs[6];
    int count = 0;

    INPUT move      = {0};
    move.type       = INPUT_MOUSE;
    move.mi.dx      = (((x + sInfo.x) - sInfo.virtualX) * 65535) / sInfo.virtualWidth;
    move.mi.dy      = (((y + sInfo.y) - sInfo.virtualY) * 65535) / sInfo.virtualHeight;

    move.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    inputs[count++] = move;

    if (!diff)
        goto SEND_INPUT;

    if (change & rfbButton1Mask)
    {
        INPUT left      = {0};
        left.type       = INPUT_MOUSE;
        left.mi.dwFlags = (buttonMask & rfbButton1Mask) ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        inputs[count++] = left;
    }

    if (change & rfbButton2Mask)
    {
        INPUT middle      = {0};
        middle.type       = INPUT_MOUSE;
        middle.mi.dwFlags = (buttonMask & rfbButton2Mask) ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        inputs[count++]   = middle;
    }

    if (change & rfbButton3Mask)
    {
        INPUT right      = {0};
        right.type       = INPUT_MOUSE;
        right.mi.dwFlags = (buttonMask & rfbButton3Mask) ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        inputs[count++]  = right;
    }

    if (change & rfbButton4Mask)
    {
        INPUT wheelUp        = {0};
        wheelUp.type         = INPUT_MOUSE;
        wheelUp.mi.dwFlags   = MOUSEEVENTF_WHEEL;
        wheelUp.mi.mouseData = WHEEL_DELTA;
        inputs[count++]      = wheelUp;
    }

    if (change & rfbButton5Mask)
    {
        INPUT wheelDown        = {0};
        wheelDown.type         = INPUT_MOUSE;
        wheelDown.mi.dwFlags   = MOUSEEVENTF_WHEEL;
        wheelDown.mi.mouseData = -WHEEL_DELTA;
        inputs[count++]        = wheelDown;
    }

SEND_INPUT:
    SendInput(count, inputs, sizeof(INPUT));
}

static HICON createTaskbarIcon()
{
    const int size = 32;

    HDC hdcScreen    = GetDC(NULL);
    HDC hdcMem       = CreateCompatibleDC(hdcScreen);
    HBITMAP hbmColor = CreateCompatibleBitmap(hdcScreen, size, size);
    HBITMAP hbmOld   = (HBITMAP)SelectObject(hdcMem, hbmColor);

    RECT rect = {0, 0, size, size};
    FillRect(hdcMem, &rect, (HBRUSH)GetStockObject(BLACK_BRUSH));

    HFONT hFont = CreateFont(
        -24,                  // Height (negative for character height)
         0, 0, 0,             // Width, Escapement, Orientation
         FW_BOLD,             // Bold weight
         FALSE, FALSE, FALSE, // Italic, Underline, StrikeOut
         DEFAULT_CHARSET,
         OUT_DEFAULT_PRECIS,
         CLIP_DEFAULT_PRECIS,
         DEFAULT_QUALITY,
         DEFAULT_PITCH | FF_SWISS,
         "Arial"
    );

    HFONT hFontOld = (HFONT)SelectObject(hdcMem, hFont);

    // Set text color to white and make background transparent
    SetTextColor(hdcMem, RGB(255, 255, 255));
    SetBkMode(hdcMem, TRANSPARENT);

    // Draw a centered white "R"
    DrawText(hdcMem, "R", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    SelectObject(hdcMem, hFontOld);
    DeleteObject(hFont);

    HBITMAP hbmMask = CreateBitmap(size, size, 1, 1, NULL);

    ICONINFO iconInfo;
    iconInfo.fIcon    = TRUE;
    iconInfo.xHotspot = 0;
    iconInfo.yHotspot = 0;
    iconInfo.hbmMask  = hbmMask;
    iconInfo.hbmColor = hbmColor;

    HICON hIcon = CreateIconIndirect(&iconInfo);

    SelectObject(hdcMem, hbmOld);
    DeleteDC(hdcMem);
    ReleaseDC(NULL, hdcScreen);

    DeleteObject(hbmColor);
    DeleteObject(hbmMask);

    return hIcon;
}

static LRESULT CALLBACK taskbarWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
        case WM_INITMENUPOPUP:
        {
            HMENU hDispMenu = (HMENU)wParam;

            if (LOWORD(lParam) == 0)
            {
                int count = GetMenuItemCount(hDispMenu);
                while (count-- > 0)
                    DeleteMenu(hDispMenu, 0, MF_BYPOSITION);

                for (int i = 0; i < sInfo.numMonitors; i++)
                {
                    AppendMenuW(hDispMenu, MF_STRING, IDM_DISP_BASE + i, sInfo.monitorNames[i]);
                }

                SetMenuDefaultItem(hDispMenu, IDM_DISP_BASE + sInfo.currentMonitor, FALSE);
                DrawMenuBar(hWnd);
            }
            break;
        }
        case WM_SYSCOMMAND:
        {
            LRESULT ret = DefWindowProc(hWnd, msg, wParam, lParam);
            if ((wParam & 0xFFF0) == SC_RESTORE)
            {
                UINT dpi;
                GetDpiForMonitor(sInfo.hCurrentMonitor, MDT_EFFECTIVE_DPI, &dpi, &dpi);

                RECT rect = taskbarWndRect;
                AdjustWindowRectExForDpi(&rect, taskbarWndStyle, TRUE, 0, dpi);

                int32_t w = rect.right  - rect.left;
                int32_t h = rect.bottom - rect.top;
                int32_t x = sInfo.x + (sInfo.width  - w) / 2;
                int32_t y = sInfo.y + (sInfo.height - h) / 2;

                SetWindowPos(hWnd, NULL, x, y, w, h, SWP_NOZORDER);
            }
            return ret;
        }
        case WM_COMMAND:
        {
            int id = LOWORD(wParam);

            if (id >= IDM_DISP_BASE && id < IDM_DISP_BASE + sInfo.numMonitors)
            {
                sInfo.currentMonitor = id - IDM_DISP_BASE;
                ShowWindow(hWnd, SW_MINIMIZE);

                if (rfbScreen->topmostWindow)
                {
                    Sleep(1000);
                    SendMessage(hWnd, WM_SYSCOMMAND, SC_RESTORE, 0);
                }
            }
            break;
        }
        case WM_DESTROY:
            rfbShutdownServer(rfbScreen, TRUE);
            break;
        default:
            return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    return 0;
}

static DWORD WINAPI taskbarWindowHandler(LPVOID param)
{
    char* className = "TaskbarWindowClass";
    HMODULE hwnd    = GetModuleHandle(NULL);

    WNDCLASS wc      = {0};
    wc.lpfnWndProc   = taskbarWndProc;
    wc.hInstance     = hwnd;
    wc.lpszClassName = className;
    wc.hIcon         = createTaskbarIcon();
    wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW+1);

    if (!RegisterClass(&wc))
        return 1;

    HMENU hMenuBar  = CreateMenu();
    HMENU hDispMenu = CreatePopupMenu();

    AppendMenuW(hMenuBar, MF_POPUP, (UINT_PTR)hDispMenu, L"Displays");

    RECT rect = taskbarWndRect;
    AdjustWindowRect(&rect, taskbarWndStyle, TRUE);

    int32_t w = rect.right  - rect.left;
    int32_t h = rect.bottom - rect.top;
    int32_t x = sInfo.x + (sInfo.width  - w) / 2;
    int32_t y = sInfo.y + (sInfo.height - h) / 2;

    HWND hWnd = CreateWindow(className, "Remote session running",
                             taskbarWndStyle,
                             x, y, w, h,
                             NULL, hMenuBar, hwnd, NULL);

    if (!hWnd)
        return 1;

    if (rfbScreen->topmostWindow)
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);

        ShowWindow(hWnd, SW_MINIMIZE);

    MSG msg;
    BOOL bRet;

    while ((bRet = GetMessage(&msg, NULL, 0, 0)) != 0)
    {
        if (bRet != -1)
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }

    return 0;
}

static void clientGone(rfbClientPtr cl)
{
    rfbShutdownServer(cl->screen, TRUE);
}

static enum rfbNewClientAction newClient(rfbClientPtr cl)
{
    if (clientConnected)
        return RFB_CLIENT_REFUSE;

    clientConnected = TRUE;

    cl->clientGoneHook = clientGone;
    return RFB_CLIENT_ACCEPT;
}

static void changeWallpaper()
{
    char remoteWallpaperFullPath[MAX_PATH];

    if (!GetFullPathName(remoteWallpaperPath, MAX_PATH, remoteWallpaperFullPath, NULL))
    {
        return;
    }

    SystemParametersInfo(SPI_GETDESKWALLPAPER, MAX_PATH, savedWallpaperPath, 0);

    if (savedWallpaperPath[0] != '\0' &&
        GetFileAttributes(savedWallpaperPath) != INVALID_FILE_ATTRIBUTES &&
        GetFileAttributes(remoteWallpaperFullPath) != INVALID_FILE_ATTRIBUTES)
    {
        SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, remoteWallpaperFullPath,
                             SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE);
    }
}

static void restoreWallpaper()
{
    if (savedWallpaperPath[0] != '\0' &&
        GetFileAttributes(savedWallpaperPath) != INVALID_FILE_ATTRIBUTES)
    {
        SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, savedWallpaperPath,
                             SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE);
    }
}

static BOOL WINAPI consoleHandler(DWORD ctrlType)
{
    switch (ctrlType)
    {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT:
            rfbShutdownServer(rfbScreen, TRUE);
            return TRUE;
        default:
            return FALSE;
    }
}

static DWORD WINAPI timeoutHandler(LPVOID param)
{
    Sleep(MAX_WAIT_TIME_MS);

    if (!clientConnected)
    {
        rfbLog("Timeout reached, no client connected\n");
        rfbShutdownServer(rfbScreen, TRUE);
    }

    return 0;
}

void setCwd()
{
    wchar_t exePath[MAX_PATH];

    if (GetModuleFileNameW(NULL, exePath, MAX_PATH) == 0)
        return;

    HRESULT hr = PathCchRemoveFileSpec(exePath, MAX_PATH);

    if (FAILED(hr))
        return;

    SetCurrentDirectoryW(exePath);
}

static BOOL tryOpenClipboard(HWND hwnd, DWORD timeout)
{
    const DWORD step = 10;
    DWORD waited     = 0;

    while (waited < timeout)
    {
        if (OpenClipboard(hwnd))
            return TRUE;

        if (GetLastError() != ERROR_ACCESS_DENIED)
            return FALSE;

        Sleep(step);
        waited += step;
    }

    return FALSE;
}

static void handleClientXCutText(char* text, int len, rfbClientPtr cl)
{
    wchar_t* wText;
    int wLen = MultiByteToWideChar(CP_UTF8, 0, text, len, NULL, 0);

    if (wLen == 0)
        return;

    wText = (wchar_t*)malloc((wLen + 1) * sizeof(wchar_t));

    if (!wText)
        return;

    MultiByteToWideChar(CP_UTF8, 0, text, len, wText, wLen);
    wText[wLen] = L'\0';

    if (tryOpenClipboard(NULL, 200))
    {
        EmptyClipboard();

        ignoreClipboardUpdate = TRUE;

        HGLOBAL hglb = GlobalAlloc(GMEM_MOVEABLE, (wLen + 1) * sizeof(wchar_t));

        if (hglb)
        {
            wchar_t* p = (wchar_t*)GlobalLock(hglb);
            memcpy(p, wText, (wLen + 1) * sizeof(wchar_t));

            GlobalUnlock(hglb);
            SetClipboardData(CF_UNICODETEXT, hglb);
        }

        CloseClipboard();
    }

    free(wText);
}

static LRESULT CALLBACK clipboardWndProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    if (message != WM_CLIPBOARDUPDATE)
        goto DONE;

    if (!tryOpenClipboard(hWnd, 200))
        goto DONE;

    if (ignoreClipboardUpdate)
    {
        ignoreClipboardUpdate = FALSE;
        goto DONE;
    }

    HANDLE hData = GetClipboardData(CF_UNICODETEXT);

    if (hData)
    {
        wchar_t* wText = (wchar_t*)GlobalLock(hData);

        if (wText)
        {
            int utf8Len = WideCharToMultiByte(CP_UTF8, 0, wText, -1, NULL, 0, NULL, NULL);

            if (utf8Len > 0)
            {
                char* utf8Text = (char*)malloc(utf8Len);

                if (utf8Text)
                {
                    WideCharToMultiByte(CP_UTF8, 0, wText, -1, utf8Text, utf8Len, NULL, NULL);
                    rfbSendServerCutTextUTF8(rfbScreen, utf8Text, (int)strlen(utf8Text), NULL, 0);
                    free(utf8Text);
                }
            }

            GlobalUnlock(hData);
        }
    }
    else
    {
        rfbSendServerCutTextUTF8(rfbScreen, "", 0, NULL, 0);
    }

DONE:
    CloseClipboard();
    return DefWindowProc(hWnd, message, wParam, lParam);
}

static void clipboardLocalMsgLoop()
{
    MSG msg;
    BOOL bRet;

    while ((bRet = GetMessage(&msg, NULL, 0, 0)) != 0)
    {
        if (bRet == -1)
        {
            rfbLog("Error reading from message queue 0x%08X\n", GetLastError());
        }
        else
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }
}

static DWORD WINAPI clipboardLocalHandler(LPVOID param)
{
    char* className = "ClipboardListenerWindowClass";

    HWND hClipboardWnd = NULL;
    HMODULE hwnd       = GetModuleHandle(NULL);

    WNDCLASS wc      = {0};
    wc.lpfnWndProc   = clipboardWndProc;
    wc.hInstance     = hwnd;
    wc.lpszClassName = className;

    if (!RegisterClass(&wc))
        goto FAIL;

    hClipboardWnd = CreateWindow(className, "Clipboard Listener", 0,
                                 0, 0, 0, 0, NULL, NULL, hwnd, NULL);

    if (!hClipboardWnd)
        goto FAIL;

    if (!AddClipboardFormatListener(hClipboardWnd))
        goto FAIL;

    clipboardLocalMsgLoop();
    return 0;

FAIL:
    rfbLog("Failed to initialize clipboard local handler\n");
    return 1;
}

static void initServerFormat()
{
    rfbScreen->serverFormat.bitsPerPixel = 32;
    rfbScreen->serverFormat.depth        = 24;
    rfbScreen->serverFormat.redShift     = 16;
    rfbScreen->serverFormat.greenShift   = 8;
    rfbScreen->serverFormat.blueShift    = 0;
    rfbScreen->serverFormat.redMax       = 255;
    rfbScreen->serverFormat.greenMax     = 255;
    rfbScreen->serverFormat.blueMax      = 255;
}

static BOOL isOnTargetMonitor(HWND hwnd)
{
    HMONITOR hCur = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
    return (hCur == sInfo.hCurrentMonitor);
}

static void sendWinShiftArrow()
{
    INPUT inputs[6] = {};

    inputs[0].type       = INPUT_KEYBOARD;
    inputs[0].ki.wVk     = VK_LWIN;
    inputs[0].ki.dwFlags = 0;

    inputs[1].type       = INPUT_KEYBOARD;
    inputs[1].ki.wVk     = VK_LSHIFT;
    inputs[1].ki.dwFlags = 0;

    inputs[2].type       = INPUT_KEYBOARD;
    inputs[2].ki.wVk     = VK_RIGHT;
    inputs[2].ki.dwFlags = KEYEVENTF_EXTENDEDKEY;

    inputs[3].type       = INPUT_KEYBOARD;
    inputs[3].ki.wVk     = VK_RIGHT;
    inputs[3].ki.dwFlags = KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP;

    inputs[4].type       = INPUT_KEYBOARD;
    inputs[4].ki.wVk     = VK_LSHIFT;
    inputs[4].ki.dwFlags = KEYEVENTF_KEYUP;

    inputs[5].type       = INPUT_KEYBOARD;
    inputs[5].ki.wVk     = VK_LWIN;
    inputs[5].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(6, inputs, sizeof(INPUT));
}

static void moveWindowToMonitor(HWND hwnd)
{
    Sleep(500);

    for (int i = 0; i < MAX_MONS; i++)
    {
        if (isOnTargetMonitor(hwnd))
            break;

        sendWinShiftArrow();

        Sleep(100);
    }
}

static void CALLBACK winEventProc(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG idObject,
                                  LONG idChild, DWORD dwEventThread, DWORD dwmsEventTime)
{
    if (event != EVENT_OBJECT_SHOW || idObject != OBJID_WINDOW ||
        idChild != CHILDID_SELF)
        return;

    HWND hRoot = GetAncestor(hwnd, GA_ROOTOWNER);

    if (GetWindow(hRoot, GW_OWNER) != NULL)
        return;

    if (!IsWindowVisible(hRoot) || GetWindowTextLength(hRoot) == 0)
        return;

    if (GetProp(hRoot, "MovedToTargetMonitor") != NULL)
        return;

    LONG style = GetWindowLong(hRoot, GWL_STYLE);

    if (!(style & WS_VISIBLE) || !(style & WS_SIZEBOX))
        return;

    LONG allowed = WS_OVERLAPPEDWINDOW | WS_POPUPWINDOW | WS_POPUP;
    if (!(style & allowed))
        return;

    if (!isOnTargetMonitor(hRoot))
        moveWindowToMonitor(hRoot);

    SetProp(hRoot, "MovedToTargetMonitor", (HANDLE)1);
}

static DWORD WINAPI winEventHandler(LPVOID lpParam)
{
    HWINEVENTHOOK hEventHook = SetWinEventHook(
        EVENT_OBJECT_SHOW,
        EVENT_OBJECT_SHOW,
        NULL,
        winEventProc,
        0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
    );

    MSG msg;
    BOOL bRet;

    while ((bRet = GetMessage(&msg, NULL, 0, 0)) != 0)
    {
        if (bRet != -1)
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }

    UnhookWinEvent(hEventHook);
    return 0;
}

int main(int argc, char** argv)
{
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    SetProcessDPIAware();

    // Starting monitor
    sInfo.currentMonitor = 0;

    // Doing this here to ensure first call to
    // initScreenCapture logs output if requested
    for (int i = 1; i < argc; i++)
    {
       if (strcmp(argv[i], "-logEnable") == 0)
            rfbLogEnable(TRUE);
    }

    if (FAILED(initScreenCapture()))
    {
        rfbLog("Failed to initialize Desktop Duplication API\n");
        return 1;
    }

    int width          = sInfo.width;
    int height         = sInfo.height;
    int currentMonitor = sInfo.currentMonitor;

    rfbScreen = rfbGetScreen(&argc, argv, width, height, 8, 3, 4);
    rfbLog("Remote start\n");

    if (!rfbScreen)
        return 1;

    rfbScreen->port = 5901;

    rfbScreen->frameBuffer = malloc(width * height * 4);

    rfbScreen->newClientHook = newClient;

    rfbScreen->desktopName    = "Remote";
    rfbScreen->neverShared    = TRUE;
    rfbScreen->dontDisconnect = TRUE;
    rfbScreen->kbdAddEvent    = dokbd;
    rfbScreen->ptrAddEvent    = doptr;

    rfbScreen->deferUpdateTime   = 0;
    rfbScreen->maxRectsPerUpdate = 500;

    initServerFormat();

    rfbScreen->setXCutTextUTF8 = handleClientXCutText;

    CreateThread(NULL, 0, clipboardLocalHandler, NULL, 0, NULL);

    rfbInitServer(rfbScreen);

    if (rfbScreen->listenSock == RFB_INVALID_SOCKET)
    {
        rfbLog("Failed to start server\n");
        return 1;
    }

    CreateThread(NULL, 0, timeoutHandler,  NULL, 0, NULL);
    startCursorThread();
    CreateThread(NULL, 0, winEventHandler, NULL, 0, NULL);

    SetConsoleCtrlHandler(consoleHandler, TRUE);

    setCwd();

    if (rfbScreen->changeWallpaper)
        changeWallpaper();

    CreateThread(NULL, 0, taskbarWindowHandler, NULL, 0, NULL);

    rfbRunEventLoop(rfbScreen, -1, TRUE);

    while (rfbIsActive(rfbScreen))
    {
        HRESULT hr = sInfo.screenCapture(width, height);

        if (hr == DXGI_ERROR_ACCESS_LOST || hr == DXGI_ERROR_INVALID_CALL ||
            currentMonitor != sInfo.currentMonitor)
        {
            Sleep(RES_CHANGE_WAIT_TIME_MS);

            rfbLog("Reinitializing screen capture\n");

            stopCursorThreadAndWait();

            unsigned char* oldfb = (unsigned char*)rfbScreen->frameBuffer;
            cleanupScreenCapture();
            free(oldfb);

            if (FAILED(initScreenCapture()))
            {
                rfbLog("Failed to reinitialize Desktop Duplication API\n");
                return 1;
            }

            width          = sInfo.width;
            height         = sInfo.height;
            currentMonitor = sInfo.currentMonitor;

            unsigned char* newfb = (unsigned char*)malloc(width * height * 4);

            rfbNewFramebuffer(rfbScreen, newfb, width, height, 8, 3, 4);
            initServerFormat();
            startCursorThread();
        }
        else if (FAILED(hr))
        {
            rfbLog("Error during screen capture 0x%08X\n", hr);
        }
    }

    if (rfbScreen->changeWallpaper)
        restoreWallpaper();

    cleanupScreenCapture();
    free(rfbScreen->frameBuffer);
    rfbScreenCleanup(rfbScreen);

    // Unmount z: drive
    system("cmd.exe /C net use z: /delete /y > nul");

    rfbLog("Remote done\n");
    return 0;
}
