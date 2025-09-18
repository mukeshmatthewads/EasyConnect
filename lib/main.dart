// main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:permission_handler/permission_handler.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

const String appId = "913a078582c84e7abd06c2853019b769"; // Replace with Agora App ID
const String token = ""; // leave blank if App Certificate disabled
const String SERVER = "http://10.2.0.0:3000"; // replace with LAN IP for real devices

void main() {
  runApp(const DDConnectApp());
}

class DDConnectApp extends StatelessWidget {
  const DDConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "D&D Connect",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: Colors.grey.shade100,
      ),
      home: const LoginScreen(),
    );
  }
}

/// ---------------- Login screen ----------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  bool _loading = false;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userId = prefs.getString("userId");
    });
  }

  Future<void> _login() async {
    if (_phoneController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter phone/email")),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final resp = await http.post(
        Uri.parse("$SERVER/login"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"phone": _phoneController.text}),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final backendId = data["userId"];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("userId", backendId);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => CallScreen(userId: backendId)),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Login failed")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error: $e")));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(title: const Text("D&D Login")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text("Your device ID: ${_userId ?? "..."}",
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: "Phone or Email (test)",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.phone),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loading ? null : _login,
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48)),
                    child: _loading
                        ? const CircularProgressIndicator()
                        : const Text("Login"),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// ---------------- Call Screen ----------------
class CallScreen extends StatefulWidget {
  final String userId;
  const CallScreen({super.key, required this.userId});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late IO.Socket _socket;
  final TextEditingController _receiverController = TextEditingController();
  final TextEditingController _textController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];

  // Agora
  late final RtcEngine _engine;
  bool _joined = false;
  final List<int> _remoteUids = [];

  // STT & TTS
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;
  bool _captionsEnabled = false;
  bool _ttsEnabled = false;
  String _peerCaption = "";

  String? _activePeerId;
  String? _activeChannel;

  // --- Call Duration ---
  DateTime? _callStartTime;
  Timer? _callTimer;
  Duration _callDuration = Duration.zero;

  void _startCallTimer() {
    _callStartTime = DateTime.now();
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStartTime != null) {
        setState(() {
          _callDuration = DateTime.now().difference(_callStartTime!);
        });
      }
    });
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
    setState(() {
      _callDuration = Duration.zero;
      _callStartTime = null;
    });
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    final hours = d.inHours;
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    if (hours > 0) {
      return "$hours:$minutes:$seconds";
    } else {
      return "$minutes:$seconds";
    }
  }

  @override
  void initState() {
    super.initState();
    _initSocket();
    _initAgora();
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
  }

  // ---------------- Socket ----------------
  void _initSocket() {
    _socket = IO.io(
        SERVER,
        IO.OptionBuilder()
            .setTransports(["websocket"])
            .disableAutoConnect()
            .build());
    _socket.connect();

    _socket.onConnect((_) {
      _socket.emit("register", widget.userId);
    });

    _socket.on("message:new", (data) {
      final msg = Map<String, dynamic>.from(data);
      setState(() {
        _messages.add({
          "text": msg["text"],
          "sender": msg["sender"],
          "isMe": msg["sender"] == widget.userId,
          "useTTS": msg["useTTS"] ?? false
        });
      });
      if (msg["receiver"] == widget.userId && msg["useTTS"] == true) {
        _flutterTts.speak(msg["text"] ?? "");
      }
    });

    _socket.on("call:incoming", (data) {
      final from = data["from"];
      final channelName = data["channelName"];
      _showIncomingCallDialog(from, channelName);
    });

    _socket.on("call:accepted", (data) {
      _joinAgoraChannel(data["channelName"]);
    });

    _socket.on("call:missed", (data) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("User ${data['to']} is offline")));
    });

    _socket.on("transcript", (data) {
      setState(() => _peerCaption = data["text"] ?? "");
    });

    _socket.on("call:ended", (_) => _leaveAgoraChannel());
  }

  // ---------------- Agora ----------------
  Future<void> _initAgora() async {
    await Permission.microphone.request();
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(appId: appId));
    await _engine.enableAudio();

    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        setState(() => _joined = true);
        _startCallTimer(); // ✅ start timer on join
        if (_captionsEnabled) _startLocalTranscribe();
      },
      onUserJoined: (connection, uid, elapsed) {
        setState(() => _remoteUids.add(uid));
      },
      onUserOffline: (connection, uid, reason) {
        setState(() => _remoteUids.remove(uid));
      },
      onLeaveChannel: (connection, stats) {
        _stopCallTimer(); // ✅ stop timer on leave
      },
    ));
  }

  void _callUser() {
    final to = _receiverController.text.trim();
    if (to.isEmpty) return;
    _activePeerId = to;
    final ids = [widget.userId, to]..sort();
    final channelName = "user_${ids[0]}_${ids[1]}";
    _activeChannel = channelName;

    _socket.emit("call:request",
        {"from": widget.userId, "to": to, "channelName": channelName});
  }

  void _showIncomingCallDialog(String from, String channelName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Incoming Call"),
        content: Text("Call from $from"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Decline")),
          ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _activePeerId = from;
                _activeChannel = channelName;
                _socket.emit("call:accept", {
                  "from": widget.userId,
                  "to": from,
                  "channelName": channelName
                });
                _joinAgoraChannel(channelName);
              },
              child: const Text("Accept")),
        ],
      ),
    );
  }

  Future<void> _joinAgoraChannel(String channelName) async {
    if (_joined) return; // avoid double join
    await _engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: int.tryParse(widget.userId) ?? Random().nextInt(99999),
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,   // ✅ ensure mic works
        autoSubscribeAudio: true,       // ✅ ensure speaker works
      ),
    );
    setState(() {
      _joined = true;
    });
  }

  Future<void> _leaveAgoraChannel() async {
    if (!_joined) return;
    await _engine.leaveChannel();
    if (_activePeerId != null) {
      _socket.emit("call:end", {"from": widget.userId, "to": _activePeerId});
    }
    setState(() {
      _joined = false;
      _remoteUids.clear();
      _peerCaption = "";
      _activePeerId = null;
      _activeChannel = null;
    });
    _stopLocalTranscribe();
    _stopCallTimer();
  }

  // ---------------- STT ----------------
  Future<void> _startLocalTranscribe() async {
    bool available = await _speech.initialize();
    if (!available) return;
    _speech.listen(onResult: (val) {
      final text = val.recognizedWords;
      if (_activePeerId != null) {
        _socket.emit("transcript",
            {"from": widget.userId, "to": _activePeerId, "text": text});
      }
    }, listenMode: stt.ListenMode.dictation);
  }

  void _stopLocalTranscribe() {
    try {
      _speech.stop();
    } catch (_) {}
  }

  // ---------------- Messages ----------------
  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _activePeerId == null) return;
    final payload = {
      "text": text,
      "sender": widget.userId,
      "receiver": _activePeerId!,
      "useTTS": _ttsEnabled
    };
    _socket.emit("message:send", payload);
    setState(() {
      _messages.add({
        "text": text,
        "sender": widget.userId,
        "isMe": true,
        "useTTS": _ttsEnabled
      });
      _textController.clear();
    });
  }

  @override
  void dispose() {
    _socket.dispose();
    _engine.release();
    _speech.stop();
    _stopCallTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "D&D Connect - You: ${widget.userId} ${_joined ? "(${_formatDuration(_callDuration)})" : ""}",
        ),
      ),
      body: Column(children: [
        // Call input + buttons
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _receiverController,
                decoration: InputDecoration(
                  labelText: "Enter other userId to call",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FloatingActionButton(
              heroTag: "callBtn",
              backgroundColor: Colors.green,
              onPressed: _callUser,
              child: const Icon(Icons.call),
            ),
            const SizedBox(width: 12),
            FloatingActionButton(
              heroTag: "endBtn",
              backgroundColor: Colors.red,
              onPressed: _joined ? _leaveAgoraChannel : null,
              child: const Icon(Icons.call_end),
            ),
          ]),
        ),

        // Captions
        if (_captionsEnabled)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _peerCaption.isEmpty
                  ? "Captions will appear here..."
                  : _peerCaption,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ),

        // Toggle buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Row(children: [
                Switch(
                    value: _captionsEnabled,
                    activeColor: Colors.deepPurple,
                    onChanged: (v) {
                      setState(() => _captionsEnabled = v);
                      if (v && _joined) {
                        _startLocalTranscribe();
                      } else {
                        _stopLocalTranscribe();
                      }
                    }),
                const Text("Captions"),
              ]),
              Row(children: [
                Switch(
                    value: _ttsEnabled,
                    activeColor: Colors.deepPurple,
                    onChanged: (v) => setState(() => _ttsEnabled = v)),
                const Text("TTS"),
              ]),
            ],
          ),
        ),

        // Messages
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (ctx, i) {
              final m = _messages[i];
              return Align(
                alignment:
                    m["isMe"] ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: m["isMe"]
                        ? Colors.deepPurple.shade100
                        : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(m["text"], style: const TextStyle(fontSize: 16)),
                ),
              );
            },
          ),
        ),

        // Message input
        SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.05), blurRadius: 5)
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                        hintText: "Type message...", border: InputBorder.none),
                    onSubmitted: (_) => _sendTextMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.deepPurple),
                  onPressed: _sendTextMessage,
                )
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
