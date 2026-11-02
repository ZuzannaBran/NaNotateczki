{{flutter_js}}
{{flutter_build_config}}

(async () => {
  const pdfBaseUrl = new URL('vendor/pdfjs/4.6.82/', document.baseURI);
  try {
    const pdfjsLib = await import(new URL('pdf.min.mjs', pdfBaseUrl).href);
    pdfjsLib.GlobalWorkerOptions.workerSrc =
      new URL('pdf.worker.min.mjs', pdfBaseUrl).href;
    globalThis.pdfjsLib = pdfjsLib;
    // pdfx reads these options from the global context, not module scope.
    globalThis.pdfRenderOptions = {
      cMapUrl: new URL('cmaps/', pdfBaseUrl).href,
      cMapPacked: true,
    };
  } catch (error) {
    // A broken PDF asset must not prevent access to existing notes.
    console.error('Could not initialize the PDF renderer.', error);
  }

  await _flutter.loader.load({
    config: {
      canvasKitBaseUrl: new URL('canvaskit/', document.baseURI).href,
    },
  });
})();
