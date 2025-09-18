import asyncio
import websockets
import json
from vosk import Model, KaldiRecognizer

# Load Vosk model
model = Model("vosk-model-small-en-us-0.15")
rec = KaldiRecognizer(model, 16000)

async def transcribe(websocket):
    async for message in websocket:
        data = json.loads(message)

        if "audio" in data:
            audio_bytes = bytes(data["audio"])
            if rec.AcceptWaveform(audio_bytes):
                result = rec.Result()
            else:
                result = rec.PartialResult()
            await websocket.send(result)

        if "end" in data:
            await websocket.send(rec.FinalResult())

async def main():
    async with websockets.serve(transcribe, "0.0.0.0", 2700):
        print("✅ WebSocket STT server running on ws://0.0.0.0:2700")
        await asyncio.Future()  # run forever

if __name__ == "__main__":
    asyncio.run(main())
 