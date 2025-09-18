// server.js
// Run: node server.js
// npm install express mongoose cors body-parser socket.io

const express = require("express");
const mongoose = require("mongoose");
const cors = require("cors");
const bodyParser = require("body-parser");
const http = require("http");
const { Server } = require("socket.io");

const app = express();
const port = 3000;

app.use(cors({ origin: "*" }));
app.use(bodyParser.json());

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: "*", methods: ["GET", "POST"] },
});

// --- MongoDB connection (replace with your URI) ---
mongoose
  .connect(
    "mongodb+srv://mukeshmatthew0107_db_user:markmyword2806@nagishapp.i1ofheb.mongodb.net/nagishDB?retryWrites=true&w=majority&appName=nagishapp"
  )
  .then(() => console.log("✅ MongoDB connected!"))
  .catch((err) => console.error("❌ MongoDB connection error:", err));

// --- Schemas ---
const UserSchema = new mongoose.Schema({
  phone: { type: String, required: true },
  userId: { type: String, required: true },
});
const User = mongoose.model("User", UserSchema);

const MessageSchema = new mongoose.Schema(
  {
    text: { type: String, required: true },
    sender: { type: String, required: true },
    receiver: { type: String, required: true },
    useTTS: { type: Boolean, default: false },
  },
  { timestamps: true }
);
const Message = mongoose.model("Message", MessageSchema);

// --- In-memory mapping ---
const userSockets = {}; // { userId: socketId }

// --- Routes ---
app.get("/", (req, res) => res.send("✅ Nagish backend running!"));

app.post("/login", async (req, res) => {
  try {
    const { phone } = req.body;
    if (!phone) return res.status(400).json({ error: "Phone required" });

    let user = await User.findOne({ phone });
    if (!user) {
      const userId = Math.floor(Math.random() * 1000000).toString();
      user = new User({ phone, userId });
      await user.save();
    }
    return res.json({ userId: user.userId });
  } catch (err) {
    console.error("Login error:", err);
    res.status(500).json({ error: "Server error during login" });
  }
});

app.get("/messages/:userId", async (req, res) => {
  try {
    const { userId } = req.params;
    const messages = await Message.find({
      $or: [{ sender: userId }, { receiver: userId }],
    }).sort({ createdAt: 1 });
    return res.json(messages);
  } catch (err) {
    console.error("Fetch messages error:", err);
    res.status(500).json({ error: "Server error fetching messages" });
  }
});

// --- Socket.IO handlers ---
io.on("connection", (socket) => {
  console.log("🔌 socket connected:", socket.id);

  socket.on("register", (userId) => {
    if (!userId) return;
    userSockets[userId] = socket.id;
    console.log(`🔁 Registered user ${userId} -> ${socket.id}`);
  });

  socket.on("call:request", (payload) => {
    const { from, to, channelName } = payload;
    const destSocket = userSockets[to];
    if (destSocket) {
      io.to(destSocket).emit("call:incoming", { from, channelName });
    } else {
      const callerSocket = userSockets[from];
      if (callerSocket) {
        io.to(callerSocket).emit("call:missed", { to });
      }
    }
  });

  socket.on("call:accept", (payload) => {
    const { from, to, channelName } = payload;
    const destSocket = userSockets[to];
    if (destSocket) {
      io.to(destSocket).emit("call:accepted", { from, channelName });
    }
  });

  socket.on("call:end", (payload) => {
    const { from, to } = payload;
    const destSocket = userSockets[to];
    const callerSocket = userSockets[from];
    if (destSocket) io.to(destSocket).emit("call:ended", { from });
    if (callerSocket) io.to(callerSocket).emit("call:ended", { from });
  });

  socket.on("transcript", (payload) => {
    const { from, to, text } = payload;
    const destSocket = userSockets[to];
    if (destSocket) {
      io.to(destSocket).emit("transcript", { from, text });
    }
  });

  socket.on("message:send", async (payload) => {
    const { text, sender, receiver, useTTS } = payload;
    if (!text || !sender || !receiver) return;
    const msg = new Message({ text, sender, receiver, useTTS: !!useTTS });
    await msg.save();
    const destSocket = userSockets[receiver];
    if (destSocket) io.to(destSocket).emit("message:new", msg);
    socket.emit("message:sent", msg);
  });

  socket.on("disconnect", () => {
    Object.keys(userSockets).forEach((u) => {
      if (userSockets[u] === socket.id) {
        delete userSockets[u];
        console.log(`❌ user ${u} disconnected`);
      }
    });
  });
});

// --- Start ---
server.listen(port, "0.0.0.0", () => {
  console.log(`🚀 Server running on port ${port}`);
});

