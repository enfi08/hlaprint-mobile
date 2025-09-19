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

bool PrintPDFFile(const std::string& filePath, const std::string& printerName, bool color, bool doubleSided, int pagesStart, int pageEnd, int copies, const std::string& pageOrientation, int printJobId, std::unique_ptr<flutter::MethodResult<>> result) {
    HANDLE hPrinter = nullptr;
    std::wstring wprinter;
    wprinter.assign(printerName.begin(), printerName.end());

    if (!OpenPrinterW(const_cast<LPWSTR>(wprinter.c_str()), &hPrinter, nullptr)) {
        result->Error("PRINTER_NOT_FOUND", "Printer tidak ditemukan atau tidak bisa dibuka.");
        OutputDebugStringA("Gagal membuka printer.\n");
        return false;
    }

    // Mendapatkan ukuran DEVMODE default
    DWORD devModeSize = DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), nullptr, nullptr, 0);
    if (devModeSize <= 0) {
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_SIZE_FAILED", "Gagal mendapatkan ukuran DEVMODE.");
        return false;
    }

    // Mengalokasikan memori untuk DEVMODE
    PDEVMODE pDevMode = (PDEVMODE)GlobalAlloc(GPTR, devModeSize);
    if (!pDevMode) {
        ClosePrinter(hPrinter);
        result->Error("ALLOC_DEVMODE_FAILED", "Gagal mengalokasikan memori untuk DEVMODE.");
        return false;
    }

    // Mendapatkan DEVMODE default
    if (DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), pDevMode, nullptr, DM_OUT_BUFFER) != IDOK) {
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_FAILED", "Gagal mendapatkan DEVMODE default.");
        return false;
    }

    // --- prepare Poppler (glib) ---
    GError* gerror = nullptr;
    gchar* uri = g_filename_to_uri(filePath.c_str(), nullptr, &gerror);
    if (!uri) {
        if (gerror) {
            result->Error("FILE_URI_ERROR", gerror->message);
            g_clear_error(&gerror);
        }
        else {
            result->Error("FILE_URI_ERROR", "Gagal membentuk URI file.");
        }
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
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
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        return false;
    }

    std::string finalOrientation = pageOrientation;
    if (pageOrientation == "auto") {
        int num_pages = poppler_document_get_n_pages(doc);
        if (num_pages > 0) {
            PopplerPage* first_page = poppler_document_get_page(doc, 0);
            double width_points = 0.0, height_points = 0.0;
            poppler_page_get_size(first_page, &width_points, &height_points);
            g_object_unref(first_page);

            if (width_points > height_points) {
                finalOrientation = "landscape";
            }
            else {
                finalOrientation = "portrait";
            }
        }
        else {
            // Jika tidak ada halaman, gunakan default portrait
            finalOrientation = "portrait";
        }
    }

    // Mengatur metadata cetak
    pDevMode->dmFields |= DM_COPIES | DM_DUPLEX | DM_COLOR | DM_ORIENTATION | DM_PRINTQUALITY | DM_YRESOLUTION | DM_PAPERSIZE;
    pDevMode->dmPaperSize = DMPAPER_A4;

    // Set kualitas cetak
    pDevMode->dmPrintQuality = DMRES_HIGH;
    pDevMode->dmYResolution = pDevMode->dmPrintQuality;

    // Set jumlah salinan
    pDevMode->dmCopies = static_cast<short>(copies);

    // Set cetak bolak-balik (duplex)
    if (doubleSided) {
        if (finalOrientation == "portrait") {
            pDevMode->dmDuplex = DMDUP_VERTICAL;
        }
        else {
            pDevMode->dmDuplex = DMDUP_HORIZONTAL;
        }
    }
    else {
        pDevMode->dmDuplex = DMDUP_SIMPLEX;
    }

    // Set orientasi
    if (finalOrientation == "portrait") {
        pDevMode->dmOrientation = DMORIENT_PORTRAIT;
    }
    else {
        pDevMode->dmOrientation = DMORIENT_LANDSCAPE;
    }

    // Set warna/hitam-putih
    if (color) {
        pDevMode->dmColor = DMCOLOR_COLOR;
    }
    else {
        pDevMode->dmColor = DMCOLOR_MONOCHROME;
    }

    // Pastikan perubahan pada DEVMODE berhasil diterapkan
    if (DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER) != IDOK) {
        OutputDebugStringA("Gagal mengatur kualitas cetak tinggi. Melanjutkan dengan pengaturan default.\n");
    }

    HDC hdc = CreateDCW(nullptr, wprinter.c_str(), nullptr, pDevMode);
    GlobalFree(pDevMode);

    if (!hdc) {
        ClosePrinter(hPrinter);
        result->Error("PRINTER_NOT_FOUND", "Printer tidak ditemukan atau tidak bisa dibuka.");
        OutputDebugStringA("Gagal mendapatkan Device Context untuk printer.\n");
        return false;
    }

    DOCINFO docInfo;
    ZeroMemory(&docInfo, sizeof(docInfo));
    docInfo.cbSize = sizeof(docInfo);
    docInfo.lpszDocName = L"Flutter Print Job";

    DWORD jobId = StartDoc(hdc, &docInfo);
    if (jobId <= 0) {
        g_object_unref(doc);
        DeleteDC(hdc);
        ClosePrinter(hPrinter);
        result->Error("START_DOC_FAILED", "Gagal memulai dokumen cetak.");
        return false;
    }

    // Kirim respons awal ke Flutter bahwa pekerjaan sudah dikirim ke printer
    result->Success(flutter::EncodableValue("Sent To Printer"));

    int num_pages = poppler_document_get_n_pages(doc);

    // Logika untuk menentukan rentang halaman yang akan dicetak
    int start_index;
    int end_index;

    // Periksa validitas masukan pengguna
    if (pagesStart <= 0 || pageEnd <= 0 || pagesStart > pageEnd || pagesStart > num_pages) {
        // Jika input tidak valid, cetak semua halaman
        start_index = 0;
        end_index = num_pages;
        OutputDebugStringA(("Masukan halaman tidak valid. Mencetak semua " + std::to_string(num_pages) + " halaman.\n").c_str());
    }
    else {
        // Jika input valid, tentukan rentang yang diminta
        start_index = pagesStart - 1;
        end_index = pageEnd;
        OutputDebugStringA(("Mencetak halaman dari " + std::to_string(pagesStart) + " sampai " + std::to_string(pageEnd) + ".\n").c_str());
    }

    // Pastikan rentang halaman tidak melebihi jumlah halaman total
    end_index = std::min(num_pages, end_index);


    for (int i = start_index; i < end_index; ++i) {
        if (i < 0 || i >= num_pages) {
            continue;
        }

        PopplerPage* page = poppler_document_get_page(doc, i);
        if (!page) continue;

        if (StartPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            ClosePrinter(hPrinter);
            result->Error("START_PAGE_FAILED", "Gagal memulai halaman cetak.");
            return false;
        }

        double width_points = 0.0, height_points = 0.0;
        poppler_page_get_size(page, &width_points, &height_points);

        double scale_x = (double)GetDeviceCaps(hdc, PHYSICALWIDTH) / (width_points > 0 ? width_points : 1.0);
        double scale_y = (double)GetDeviceCaps(hdc, PHYSICALHEIGHT) / (height_points > 0 ? height_points : 1.0);
        double scale = std::min(scale_x, scale_y);

        cairo_surface_t* surface = cairo_win32_printing_surface_create(hdc);
        cairo_t* cr = cairo_create(surface);

        cairo_save(cr);
        cairo_scale(cr, scale, scale);

        poppler_page_render_for_printing(page, cr);

        cairo_restore(cr);
        cairo_destroy(cr);
        cairo_surface_destroy(surface);

        if (EndPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            ClosePrinter(hPrinter);
            result->Error("END_PAGE_FAILED", "Gagal mengakhiri halaman cetak.");
            return false;
        }

        g_object_unref(page);
    }

    EndDoc(hdc);
    DeleteDC(hdc);
    g_object_unref(doc);

    // --- LOGIKA MENUNGGU CETAKAN SELESAI ---
    OutputDebugStringA("Pekerjaan cetak dikirim. Memantau status...\n");
    DWORD level = 2;
    LPBYTE pJobInfo = NULL;
    DWORD bytesNeeded = 0;

    while (true) {
        GetJob(hPrinter, jobId, level, pJobInfo, bytesNeeded, &bytesNeeded);

        if (bytesNeeded == 0) {
            OutputDebugStringA("Pekerjaan cetak tidak ditemukan. Dianggap selesai.\n");
            break;
        }

        pJobInfo = new BYTE[bytesNeeded];

        if (GetJob(hPrinter, jobId, level, pJobInfo, bytesNeeded, &bytesNeeded)) {
            JOB_INFO_2* jobInfo = reinterpret_cast<JOB_INFO_2*>(pJobInfo);

            if (jobInfo->Status & JOB_STATUS_PRINTING) {
                OutputDebugStringA("Status: Sedang mencetak. Menunggu...\n");
                delete[] pJobInfo;
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
            else if (jobInfo->Status & (JOB_STATUS_ERROR | JOB_STATUS_PAPEROUT | JOB_STATUS_OFFLINE)) {
                OutputDebugStringA("Status: Gagal mencetak. Mengirim status error ke Dart.\n");
                std::string status = "Gagal mencetak. Status: " + std::to_string(jobInfo->Status);
                delete[] pJobInfo;
                ClosePrinter(hPrinter);
                result->Error("PRINT_JOB_FAILED", status);
                return false;
            }
            else {
                OutputDebugStringA("Status: Selesai. Mengakhiri pemantauan.\n");
                delete[] pJobInfo;
                break;
            }
        }
        else {
            OutputDebugStringA("Tidak bisa mendapatkan info pekerjaan. Mengakhiri pemantauan.\n");
            if (pJobInfo) delete[] pJobInfo;
            break;
        }
    }

    ClosePrinter(hPrinter);
    result->Success(flutter::EncodableValue("success"));
    return true;
}


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
                        const auto& color_val = args->find(flutter::EncodableValue("color"));
                        const auto& double_sided_val = args->find(flutter::EncodableValue("doubleSided"));
                        const auto& pages_start_val = args->find(flutter::EncodableValue("pagesStart"));
                        const auto& page_end_val = args->find(flutter::EncodableValue("pageEnd"));
                        const auto& copies_val = args->find(flutter::EncodableValue("copies"));
                        const auto& orientation_val = args->find(flutter::EncodableValue("pageOrientation"));
                        const auto& print_job_id_val = args->find(flutter::EncodableValue("printJobId"));

                        if (file_path_val != args->end() && printer_name_val != args->end() &&
                            color_val != args->end() && double_sided_val != args->end() &&
                            pages_start_val != args->end() && page_end_val != args->end() &&
                            copies_val != args->end() && orientation_val != args->end() &&
                            print_job_id_val != args->end()) {

                            std::string filePath = std::get<std::string>(file_path_val->second);
                            std::string printerName = std::get<std::string>(printer_name_val->second);
                            bool color = std::get<bool>(color_val->second);
                            bool doubleSided = std::get<bool>(double_sided_val->second);
                            int pagesStart = std::get<int>(pages_start_val->second);
                            int pageEnd = std::get<int>(page_end_val->second);
                            int copies = std::get<int>(copies_val->second);
                            std::string pageOrientation = std::get<std::string>(orientation_val->second);
                            int printJobId = std::get<int>(print_job_id_val->second);

                            PrintPDFFile(filePath, printerName, color, doubleSided, pagesStart, pageEnd, copies, pageOrientation, printJobId, std::move(result));
                            return;
                        }
                    }
                    OutputDebugStringA("Argumen tidak valid.\n");
                    result->Error("INVALID_ARGUMENTS", "File path or printer name not provided.");
                }
                else {
                    OutputDebugStringA("Metode tidak diimplementasikan.\\n");
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