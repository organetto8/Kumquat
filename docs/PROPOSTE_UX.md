# Proposte enhancement UX — Kumquat

**Stato attuale:** il prompt opzioni (`ParameterPrompt`, JobCenter.swift) offre solo campi di testo. Molti tool
girano con valori fissi: Compress (qualità 0.6 / CRF 28), Crop (solo auto bordi neri), Rotate (sempre 90° orario),
Flip (sempre orizzontale), Make GIF (640 px, 12 fps). Nessuna anteprima, nessun undo.

**Fatto (branch `feature/visual-tools`):** priorità 1–3; anteprima video per Trim, Speed, Crop, Make GIF;
opzioni per Compress (immagine, video con limite MB, audio), Resize, Rotate/Flip, Watermark, Normalize, Volume, Split.
**Fatto (crop/rotate con scelta):** Crop immagini e PDF con anteprima e riquadro (Auto, Libero, forme), Rotate immagini
con anteprima live e raddrizza a angolo libero (±45°), Rotate PDF con anteprima pagina, Rotate video (flag lossless su MP4/MOV).
Crop e Rotate ora mostrano sempre le opzioni (⌥ salta).
**Da fare:** tutto il resto qui sotto (waveform audio, prima/dopo immagini, griglia pagine PDF, undo, ricette…).

## Priorità

| # | Cosa | Perché prima | Stima |
|---|---|---|---|
| 1 | **ToolSheet**: nuovo prompt con tipi `.slider`, `.choice`, `.toggle`, `.timeRange`, `.rect` | prerequisito di tutto il resto | 1 giorno |
| 2 | **Media Preview Panel**: player + filmstrip, riusato da tutti i tool video | sblocca Trim, Speed, Crop, GIF | 2–3 giorni |
| 3 | **Ricorda ultimi valori** per tool + ⌥ al drop = salta prompt | piccolo, impatto quotidiano | 2 ore |

---

## 1. Video — editor visuale

Base comune: `AVPlayerView` + filmstrip (`AVAssetImageGenerator`). Quasi tutte le anteprime girano **senza
rendering FFmpeg**: velocità con `player.rate`, trim con `forwardPlaybackEndTime`, crop con una maschera sopra il video.
Limite: AVFoundation non legge MKV/WebM/AVI/WMV. Per questi: proxy 480p generato con FFmpeg (`-preset ultrafast`)
oppure solo filmstrip di frame.

| Tool | Oggi | Proposta |
|---|---|---|
| Trim | campi `m:ss` | timeline con due maniglie, playhead, tasti I/O, durata risultante live |
| Speed | campo "×" | slider 0.25–4× con preset (0.5, 1.5, 2), anteprima immediata a quella velocità, durata risultante, toggle "mantieni tono" |
| Crop | solo auto bordi neri | rettangolo trascinabile; preset 16:9, 9:16, 1:1, 4:5; auto-detect pre-selezionato |
| Compress | CRF fisso | slider qualità **o** dimensione target ("max 25 MB"), stima peso output, confronto A/B su un frame |
| Make GIF | 640 px, 12 fps fissi | selezione range su timeline, slider fps/larghezza, anteprima in loop, stima KB |

Secondari:
- **Split**: marker cliccabili sulla timeline invece di "N parti uguali"; opzione taglio per cambio scena.
- **Resize**: scelta a bottoni 2160/1080/720/480 con peso stimato, al posto del campo altezza.
- **Frames**: "ogni N secondi" oppure "frame corrente" (snapshot dal player).
- **Merge**: lista riordinabile con thumbnail prima di unire.

## 2. Audio

- **Trim / Split**: waveform con maniglie, play della sola selezione.
- **Volume**: slider dB con picco attuale e avviso clipping; anteprima in ascolto.
- **Normalize**: mostra LUFS attuali, target a preset (−14 streaming, −16 podcast).
- **Compress**: preset bitrate (64 voce, 128, 192, 320) invece di valore fisso.

## 3. Immagini

- **Compress**: slider qualità + vista prima/dopo divisa + peso ("2,4 MB → 380 KB").
- **Crop**: rettangolo manuale con preset aspect; auto-bordi resta come default.
- **Rotate / Flip**: 4 bottoni ↺ ↻ ⇆ ⇅ con thumbnail live, al posto dei valori fissi.
- **Resize**: slider % + campi px con lucchetto proporzioni + preset (1080, 2048, lato max).
- **Remove BG**: anteprima del ritaglio prima di salvare; opzione sfondo bianco/colore.

## 4. PDF

- **Extract / Split / Rotate**: griglia thumbnail pagine (`PDFThumbnailView`), selezione click/⇧-click, rotazione
  della singola pagina. Copre anche "Reorder/delete pages", oggi assente.
- **Watermark**: anteprima su pagina 1 con opacità, angolo, posizione.
- **Compress**: 3 livelli (Alta qualità / Bilanciato / Minimo) con peso stimato.
- **Password**: campo conferma + mostra/nascondi.

## 5. Sottotitoli

- **Shift Timing**: se nella cartella c'è un video con lo stesso nome, player affiancato; clic su una battuta e
  "inizia qui" calcola l'offset da solo.

## 6. Trasversali

**Flusso tool**
- Ultimi valori ricordati per tool + preset salvabili con nome.
- ⌥ al drop su un tool con opzioni = usa ultimi valori senza prompt; ⌥ su un tool zero-click = apri opzioni.
- Batch: anteprima sul primo file, ←/→ per scorrere gli altri, "applica a tutti".

**Wheel**
- Voci recenti/preferite in cima per tipo di file (es. HEIC → JPG sempre primo).
- Ricette: catena salvata come una sola voce ("Resize 50% + Strip Metadata + WebP").

**HUD job**
- Peso prima/dopo, Apri, Mostra nel Finder, trascina l'output dall'HUD direttamente in un'altra app.
- **Undo** ultimo job (output nel Cestino) da HUD e ⌘Z.
- "Riprova con altri valori" su job completato o fallito.

**Integrazione macOS**
- Quick Action nel menu contestuale Finder (Servizi).
- App Intents per Comandi rapidi (Shortcuts): ogni tool e conversione come azione.
- Opzione "sostituisci originale" (originale nel Cestino, recuperabile).
