#include <windows.h>
#include <gdiplus.h>
#include <cmath>
#include <cstdio>

int main()
{
    using namespace Gdiplus;

    GdiplusStartupInput input;
    ULONG_PTR token;
    if (GdiplusStartup(&token, &input, nullptr) != Ok) return 1;

    bool matches;
    {
        FontFamily family(L"Consolas");
        if (family.GetLastStatus() != Ok)
        {
            std::fprintf(stderr, "Consolas must be installed before running this probe.\n");
            matches = false;
        }
        else
        {
            // Consolas has different Windows cell and horizontal header metrics.
            const UINT16 em = family.GetEmHeight(FontStyleRegular);
            const UINT16 ascent = family.GetCellAscent(FontStyleRegular);
            const UINT16 descent = family.GetCellDescent(FontStyleRegular);
            const UINT16 spacing = family.GetLineSpacing(FontStyleRegular);
            Font font(&family, 100.0f, FontStyleRegular, UnitPixel);
            const REAL height = font.GetHeight(96.0f);
            std::printf("Consolas em=%u ascent=%u descent=%u spacing=%u height=%.5f\n",
                        em, ascent, descent, spacing, height);
            matches = em == 2048 && ascent == 1884 && descent == 514 && spacing == 2398 &&
                      std::fabs(height - 117.089844f) < 0.001f;
        }
    }
    GdiplusShutdown(token);
    return matches ? 0 : 1;
}
