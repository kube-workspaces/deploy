// Bounded IDD installer/uninstaller for the pinned VirtualDisplayDriver package.
// Root-enumerated UMDF driver (hardware id Root\MttVDD): creates the devnode,
// registers it, then binds the staged INF. Uninstall removes the devnode,
// restoring the previous display topology; the staged driver package is left
// for pnputil hygiene (reported, not hidden).
// No GUI, no network. Reports reboot-required honestly.
// Usage:
//   vdd-install.exe install <dir-with-inf>  — stage + create + bind
//   vdd-install.exe uninstall               — remove devnode
// Exit 0 done, 1 failed (JSON on stdout), 2 usage.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <cstdio>
#include <string>
#include <vector>

static std::string jsonEscape(const char* text) {
    std::string escaped;
    for (const unsigned char* c = reinterpret_cast<const unsigned char*>(text ? text : ""); *c; ++c) {
        if (*c == '\\' || *c == '"') {
            escaped += '\\';
            escaped += static_cast<char>(*c);
        } else if (*c < 0x20) {
            char unicode[7];
            snprintf(unicode, sizeof(unicode), "\\u%04x", static_cast<unsigned int>(*c));
            escaped += unicode;
        } else {
            escaped += static_cast<char>(*c);
        }
    }
    return escaped;
}

static void json(const char* op, bool ok, const char* detail, bool reboot) {
    const std::string escapedOp = jsonEscape(op);
    const std::string escapedDetail = jsonEscape(detail);
    printf("{\"op\":\"%s\",\"ok\":%s,\"detail\":\"%s\",\"rebootRequired\":%s}\n", escapedOp.c_str(),
        ok ? "true" : "false", escapedDetail.c_str(), reboot ? "true" : "false");
}

// Display class GUID {4d36e968-e325-11ce-bfc1-08002be10318}.
static GUID displayClass() {
    GUID guid = {0x4d36e968, 0xe325, 0x11ce,
        {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
    return guid;
}

static const wchar_t* HW_ID = L"Root\\MttVDD";

// Find a devnode whose hardware-id list contains our id, present or phantom
// (a previous partial attempt may have left a non-present node behind).
// Returns the device instance id, or empty when absent. Sets present.
static std::wstring findDevice(bool* present) {
    *present = false;
    GUID cls = displayClass();
    HDEVINFO set = SetupDiGetClassDevsW(&cls, L"Root", nullptr, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) return L"";
    std::wstring found;
    SP_DEVINFO_DATA data{};
    data.cbSize = sizeof(data);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &data); ++i) {
        DWORD type = 0, needed = 0;
        SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type,
            nullptr, 0, &needed);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || needed < 2) continue;
        std::vector<wchar_t> buffer(needed / 2 + 1, L'\0');
        if (!SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type,
                reinterpret_cast<BYTE*>(buffer.data()),
                needed, nullptr)) {
            continue;
        }
        for (const wchar_t* id = buffer.data(); *id; id += wcslen(id) + 1) {
            if (_wcsicmp(id, HW_ID) == 0 || _wcsicmp(id, L"MttVDD") == 0) {
                wchar_t instance[256]{};
                if (SetupDiGetDeviceInstanceIdW(set, &data, instance,
                        256, nullptr)) {
                    found = instance;
                    ULONG status = 0, problem = 0;
                    if (CM_Get_DevNode_Status(&status, &problem, data.DevInst, 0)
                        == CR_SUCCESS) {
                        *present = (problem != CM_PROB_PHANTOM);
                    } else {
                        *present = true;
                    }
                }
                break;
            }
        }
        if (!found.empty()) break;
    }
    SetupDiDestroyDeviceInfoList(set);
    return found;
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        json("usage", false, "install <inf-dir> | uninstall", false);
        return 2;
    }
    std::wstring op = argv[1];
    GUID cls = displayClass();
    if (op == L"install") {
        if (argc < 3) {
            json("install", false, "missing inf dir", false);
            return 2;
        }
        std::wstring inf = std::wstring(argv[2]) + L"\\MttVDD.inf";
        bool present = false;
        std::wstring existing = findDevice(&present);
        if (!existing.empty() && !present) {
            // Stale phantom from a partial attempt: remove so creation is clean.
            HDEVINFO set = SetupDiCreateDeviceInfoList(&cls, nullptr);
            if (set != INVALID_HANDLE_VALUE) {
                SP_DEVINFO_DATA data{};
                data.cbSize = sizeof(data);
                if (SetupDiOpenDeviceInfoW(set, existing.c_str(), nullptr, 0, &data)) {
                    SetupDiCallClassInstaller(DIF_REMOVE, set, &data);
                }
                SetupDiDestroyDeviceInfoList(set);
            }
            existing.clear();
        }
        if (existing.empty()) {
            // Try creation variants in order, reporting every error code:
            // the SetupDi root-device contract is version-sensitive and the
            // guest tells us which spelling it accepts.
            char tried[256]{};
            bool made = false;
            {   // Variant A: class-bound list, generated id (devcon style).
                HDEVINFO set = SetupDiCreateDeviceInfoList(&cls, nullptr);
                if (set != INVALID_HANDLE_VALUE) {
                    SP_DEVINFO_DATA data{};
                    data.cbSize = sizeof(data);
                    DWORD createErr = 0, regErr = 0;
                    bool created = SetupDiCreateDeviceInfoW(set, HW_ID, &cls, nullptr,
                        nullptr, DICD_GENERATE_ID, &data);
                    if (!created) {
                        createErr = GetLastError();
                    } else if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &data)) {
                        regErr = GetLastError();
                    } else {
                        made = true;
                    }
                    if (!made) {
                        snprintf(tried + strlen(tried), sizeof(tried) - strlen(tried),
                            "Acreate=%lu Areg=%lu ", (unsigned long)createErr,
                            (unsigned long)regErr);
                    }
                    SetupDiDestroyDeviceInfoList(set);
                } else {
                    snprintf(tried + strlen(tried), sizeof(tried) - strlen(tried),
                        "Alist=%lu ", (unsigned long)GetLastError());
                }
            }
            if (!made) {   // Variant B: explicit description alongside.
                HDEVINFO set = SetupDiCreateDeviceInfoList(&cls, nullptr);
                if (set != INVALID_HANDLE_VALUE) {
                    SP_DEVINFO_DATA data{};
                    data.cbSize = sizeof(data);
                    DWORD createErr = 0, regErr = 0;
                    bool created = SetupDiCreateDeviceInfoW(set, HW_ID, &cls,
                        L"Virtual Display Driver", nullptr, DICD_GENERATE_ID, &data);
                    if (!created) {
                        createErr = GetLastError();
                    } else if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &data)) {
                        regErr = GetLastError();
                    } else {
                        made = true;
                    }
                    if (!made) {
                        snprintf(tried + strlen(tried), sizeof(tried) - strlen(tried),
                            "Bcreate=%lu Breg=%lu ", (unsigned long)createErr,
                            (unsigned long)regErr);
                    }
                    SetupDiDestroyDeviceInfoList(set);
                }
            }
            if (!made) {   // Variant D/E: explicit instance ids, no generate flag.
                for (const wchar_t* candidate : {L"ROOT\\MttVDD\\0000", L"ROOT\\DISPLAY\\0001"}) {
                    HDEVINFO set = SetupDiCreateDeviceInfoList(&cls, nullptr);
                    if (set == INVALID_HANDLE_VALUE) continue;
                    SP_DEVINFO_DATA data{};
                    data.cbSize = sizeof(data);
                    DWORD createErr = 0, regErr = 0, propErr = 0;
                    bool created = SetupDiCreateDeviceInfoW(set, candidate, &cls,
                        L"Virtual Display Driver", nullptr, 0, &data);
                    if (!created) {
                        createErr = GetLastError();
                    } else {
                        // New devnodes need an explicit hardware id for driver matching.
                        const wchar_t hwids[] = L"Root\\MttVDD\0";
                        if (!SetupDiSetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID,
                                reinterpret_cast<const BYTE*>(hwids),
                                (DWORD)(sizeof(hwids)))) {
                            propErr = GetLastError();
                            created = false;
                        } else if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &data)) {
                            regErr = GetLastError();
                        } else {
                            made = true;
                        }
                    }
                    if (!made) {
                        // Roll back the half-created devnode before the next try.
                        if (created) SetupDiCallClassInstaller(DIF_REMOVE, set, &data);
                        snprintf(tried + strlen(tried), sizeof(tried) - strlen(tried),
                            "Dcreate=%lu Dprop=%lu Dreg=%lu ", (unsigned long)createErr,
                            (unsigned long)propErr, (unsigned long)regErr);
                    }
                    SetupDiDestroyDeviceInfoList(set);
                    if (made) break;
                }
            }
            if (!made) {
                char detail[300];
                snprintf(detail, sizeof(detail), "no creation variant worked (%s)", tried);
                json("install", false, detail, false);
                return 1;
            }
        }
        BOOL reboot = FALSE;
        if (!UpdateDriverForPlugAndPlayDevicesW(nullptr, HW_ID, inf.c_str(),
                INSTALLFLAG_FORCE, &reboot)) {
            char detail[128];
            snprintf(detail, sizeof(detail), "UpdateDriver failed err=%lu",
                (unsigned long)GetLastError());
            json("install", false, detail, reboot != FALSE);
            return 1;
        }
        char detail[260];
        snprintf(detail, sizeof(detail), "bound %ls", inf.c_str());
        // Narrow the path for the JSON detail (ASCII paths in practice).
        std::string narrow;
        for (wchar_t c : std::wstring(inf)) narrow += (c < 128 ? (char)c : '?');
        snprintf(detail, sizeof(detail), "bound %s", narrow.c_str());
        json("install", true, detail, reboot != FALSE);
        return 0;
    }
    if (op == L"uninstall") {
        // Remove EVERY matching devnode (an IDD install typically creates
        // one per virtual monitor); report the count.
        GUID cls2 = displayClass();
        HDEVINFO set = SetupDiGetClassDevsW(&cls2, L"Root", nullptr, DIGCF_ALLCLASSES);
        if (set == INVALID_HANDLE_VALUE) {
            json("uninstall", false, "enumeration failed", false);
            return 1;
        }
        int removed = 0;
        SP_DEVINFO_DATA data{};
        data.cbSize = sizeof(data);
        for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &data); ++i) {
            DWORD type = 0, needed = 0;
            SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type,
                nullptr, 0, &needed);
            if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || needed < 2) continue;
            std::vector<wchar_t> buffer(needed / 2 + 1, L'\0');
            if (!SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type,
                    reinterpret_cast<BYTE*>(buffer.data()), needed, nullptr)) {
                continue;
            }
            bool match = false;
            for (const wchar_t* id = buffer.data(); *id; id += wcslen(id) + 1) {
                if (_wcsicmp(id, HW_ID) == 0 || _wcsicmp(id, L"MttVDD") == 0) {
                    match = true;
                    break;
                }
            }
            if (match && SetupDiCallClassInstaller(DIF_REMOVE, set, &data)) ++removed;
        }
        SetupDiDestroyDeviceInfoList(set);
        char detail[128];
        snprintf(detail, sizeof(detail), "%d devnode(s) removed (driver package staged)", removed);
        json("uninstall", removed > 0, detail, false);
        return removed > 0 ? 0 : 1;
    }
    json("usage", false, "install <inf-dir> | uninstall", false);
    return 2;
}
