#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winspool.h>
#include <shlobj.h>
#include <string>
#include <thread>
#include <fstream>
#include <iostream>
#include <algorithm>
#include <glib.h>
#include <poppler/glib/poppler.h>
#include <cairo/cairo-win32.h>

#include "flutter_window.h"
#include "utils.h"

// Fungsi untuk memantau status cetak
void MonitorPrintJobStatus(DWORD jobId, HANDLE hPrinter, std::unique_ptr<flutter::MethodResult<>> result) {
    DWORD level = 2;
    LPBYTE pJobInfo = NULL;
    DWORD bytesNeeded = 0;

    OutputDebugStringA("Mulai memantau pekerjaan cetak...\n");

    std::this_thread::sleep_for(std::chrono::seconds(2));

    while (true) {
        GetJob(hPrinter, jobId, level, pJobInfo, bytesNeeded, &bytesNeeded);

        if (bytesNeeded == 0) {
            OutputDebugStringA("Pekerjaan cetak selesai dan dihapus dari antrean. Mengirim 'success' ke Dart.\n");
            result->Success(flutter::EncodableValue("success"));
            break;
        }

        pJobInfo = new BYTE[bytesNeeded];

        if (GetJob(hPrinter, jobId, level, pJobInfo, bytesNeeded, &bytesNeeded)) {
            JOB_INFO_2* jobInfo = reinterpret_cast<JOB_INFO_2*>(pJobInfo);

            if (jobInfo->Status & JOB_STATUS_PRINTING) {
                OutputDebugStringA("Status: Sedang mencetak. Menunggu...\n");
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
            else if (jobInfo->Status & (JOB_STATUS_ERROR | JOB_STATUS_PAPEROUT | JOB_STATUS_OFFLINE)) {
                OutputDebugStringA("Status: Gagal mencetak. Mengirim status error ke Dart.\n");
                std::string status = "Gagal mencetak. Status: " + std::to_string(jobInfo->Status);
                result->Success(flutter::EncodableValue(status));
                delete[] pJobInfo;
                break;
            }
            else {
                OutputDebugStringA("Status: Selesai. Mengirim 'success' ke Dart.\n");
                result->Success(flutter::EncodableValue("success"));
                delete[] pJobInfo;
                break;
            }
        }
        else {
            OutputDebugStringA("Tidak bisa mendapatkan info pekerjaan. Mengirim 'success' secara default.\n");
            result->Success(flutter::EncodableValue("success"));
            delete[] pJobInfo;
            break;
        }
        delete[] pJobInfo;
    }
}

bool PrintFile(const std::string& filePath, const std::string& printerName, std::unique_ptr<flutter::MethodResult<>> result) {
    // --- Create DC properly (avoid temporary wstring c_str() dangling) ---
    std::wstring wprinter;
    wprinter.assign(printerName.begin(), printerName.end());
    HDC hdc = CreateDCW(nullptr, wprinter.c_str(), nullptr, nullptr);
    if (!hdc) {
        result->Error("PRINTER_NOT_FOUND", "Printer tidak ditemukan atau tidak bisa dibuka.");
        OutputDebugStringA("Gagal mendapatkan Device Context untuk printer.\n");
        return false;
    }

    // --- prepare Poppler (glib) ---
    GError* gerror = nullptr;
    // Convert filename to file:// URI (handles spaces / special chars)
    gchar* uri = g_filename_to_uri(filePath.c_str(), nullptr, &gerror);
    if (!uri) {
        if (gerror) {
            result->Error("FILE_URI_ERROR", gerror->message);
            g_clear_error(&gerror);
        }
        else {
            result->Error("FILE_URI_ERROR", "Gagal membentuk URI file.");
        }
        DeleteDC(hdc);
        return false;
    }

    PopplerDocument* doc = poppler_document_new_from_file(uri, nullptr, &gerror);
    g_free(uri);
    if (!doc) {
        if (gerror) {
            result->Error("POPPLER_LOAD_ERROR", gerror->message);
            g_clear_error(&gerror);
        }
        else {
            result->Error("POPPLER_LOAD_ERROR", "Gagal memuat dokumen PDF.");
        }
        DeleteDC(hdc);
        return false;
    }

    // DOCINFO + StartDoc
    DOCINFO docInfo;
    ZeroMemory(&docInfo, sizeof(docInfo));
    docInfo.cbSize = sizeof(docInfo);
    docInfo.lpszDocName = L"Flutter Print Job";

    if (StartDoc(hdc, &docInfo) == SP_ERROR) {
        g_object_unref(doc);
        DeleteDC(hdc);
        result->Error("START_DOC_FAILED", "Gagal memulai dokumen cetak.");
        return false;
    }

    int num_pages = poppler_document_get_n_pages(doc);

    for (int i = 0; i < num_pages; ++i) {
        PopplerPage* page = poppler_document_get_page(doc, i);
        if (!page) continue;

        if (StartPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            result->Error("START_PAGE_FAILED", "Gagal memulai halaman cetak.");
            return false;
        }

        // Ukuran halaman (biasanya dalam points)
        double width_points = 0.0, height_points = 0.0;
        poppler_page_get_size(page, &width_points, &height_points);

        // Hitung skala (sama logika seperti yang kamu pakai)
        double scale_x = (double)GetDeviceCaps(hdc, PHYSICALWIDTH) / (width_points > 0 ? width_points : 1.0);
        double scale_y = (double)GetDeviceCaps(hdc, PHYSICALHEIGHT) / (height_points > 0 ? height_points : 1.0);
        double scale = std::min(scale_x, scale_y);

        // Create printing surface + cairo context
        cairo_surface_t* surface = cairo_win32_printing_surface_create(hdc);
        cairo_t* cr = cairo_create(surface);

        // apply scale
        cairo_save(cr);
        cairo_scale(cr, scale, scale);

        // <-- THIS is the correct call for printing with poppler-glib -->
        poppler_page_render_for_printing(page, cr);

        cairo_restore(cr);
        cairo_destroy(cr);
        cairo_surface_destroy(surface);

        if (EndPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            result->Error("END_PAGE_FAILED", "Gagal mengakhiri halaman cetak.");
            return false;
        }

        g_object_unref(page);
    }

    // Selesai
    EndDoc(hdc);
    DeleteDC(hdc);
    g_object_unref(doc);

    result->Success(flutter::EncodableValue("success"));
    return true;
}


// Fungsi registrasi channel dan wWinMain tetap sama seperti sebelumnya
void RegisterMethodChannel(flutter::FlutterViewController* flutter_controller) {
    OutputDebugStringA("Mendaftarkan Method Channel...\n");
    auto channel = std::make_unique<flutter::MethodChannel<>>(
        flutter_controller->engine()->messenger(), "com.hlaprint.app/printing",
        &flutter::StandardMethodCodec::GetInstance());

    channel->SetMethodCallHandler(
        [](const flutter::MethodCall<>& call,
            std::unique_ptr<flutter::MethodResult<>> result) {
                if (call.method_name().compare("printPDF") == 0) {
                    OutputDebugStringA("Panggilan 'printPDF' diterima.\n");
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    if (args) {
                        const auto& file_path_val = args->find(flutter::EncodableValue("filePath"));
                        const auto& printer_name_val = args->find(flutter::EncodableValue("printerName"));
                        if (file_path_val != args->end() && printer_name_val != args->end()) {
                            std::string filePath = std::get<std::string>(file_path_val->second);
                            std::string printerName = std::get<std::string>(printer_name_val->second);
                            PrintFile(filePath, printerName, std::move(result));
                            return;
                        }
                    }
                    OutputDebugStringA("Argumen tidak valid.\n");
                    result->Error("INVALID_ARGUMENTS", "File path or printer name not provided.");
                }
                else {
                    OutputDebugStringA("Metode tidak diimplementasikan.\n");
                    result->NotImplemented();
                }
        });
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
    _In_ wchar_t* command_line, _In_ int show_command) {
    if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
        CreateAndAttachConsole();
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    std::vector<std::string> command_line_arguments =
        GetCommandLineArguments();

    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (!window.Create(L"hlaprint", origin, size)) {
        return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    if (window.GetFlutterViewController()) {
        RegisterMethodChannel(window.GetFlutterViewController());
    }

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
    }

    ::CoUninitialize();
    return EXIT_SUCCESS;
}