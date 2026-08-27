# Meeting Notes

Record a meeting on your watch, sync it to your phone, and get back a clean, structured summary — participants, decisions, and action items — without typing a thing.

This repo has three parts that work together:

- **`backend/`** — a FastAPI service that transcribes audio (Groq Whisper) and turns the transcript into structured notes (Groq LLM via LangGraph).
- **`meeting_notes_watch/`** — a Flutter app for a wearable. Records the meeting in 30-second chunks and streams them to the phone as they're captured.
- **`meeting_notes_app/`** — a Flutter phone app. Receives audio chunks from the watch over Nearby Connections, forwards them to the backend for transcription, and shows the final formatted notes.

## How it works

```
Watch (records audio) --Nearby Connections--> Phone --HTTP--> Backend --> Groq (Whisper + LLM)
```

1. On the watch, you set the participant count and their roles, then hit record.
2. Audio is captured in chunks and sent to the paired phone app in real time.
3. The phone forwards each chunk to the backend's `/transcribe-chunk` endpoint to be transcribed.
4. Once the meeting ends, the full transcript is sent to `/process-meeting`, which uses an LLM to infer who said what and produce a summary, key discussion points, decisions, and action items.

## Backend

**Stack:** FastAPI, LangGraph, LangChain, Groq (Whisper for transcription, an LLM for note formatting)

### Setup

```bash
cd backend
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Create a `.env` file in `backend/`:

```
GROQ_API_KEY=your_groq_api_key
```

Run it:

```bash
uvicorn main:app --reload
```

### Endpoints

- `POST /process-audio-meeting` — upload a full audio file + meeting metadata (participant count, roles). Returns the transcript and formatted notes.
- `POST /process-meeting` — send raw transcript text + metadata directly. Skips transcription, useful for testing.
- `POST /transcribe-chunk` — transcribe a single audio chunk (used for the watch's real-time streaming flow).

There are also two small scripts for local testing: `test_whisper.py`, `test_groq.py`, and `list_models.py` (lists the Groq models available to your API key).

## Mobile apps

Both apps are standard Flutter projects.

```bash
cd meeting_notes_app   # or meeting_notes_watch
flutter pub get
flutter run
```

The watch and phone apps discover each other automatically using Nearby Connections (service ID `meeting_notes_sync`), so both devices need Bluetooth/Wi-Fi and location permissions granted.

If you'd rather install than build, you can generate an APK for either app with `flutter build apk` — the file will be under `build/app/outputs/flutter-apk/` in each project.

## Notes

- This is a work in progress — expect rough edges.
- `backend/data/example.m4a` is a sample recording you can use to test transcription without a watch.
