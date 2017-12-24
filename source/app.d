import std.socket;
import std.concurrency;
import util;

class User {
public:
	static User[string] users;
	static int[string] actives;
	static Connection[string] waitings;

	static void register(string username, string password) {
		if (username in users) {
			throw new Exception("username already used");
		}
		if (username.length == 0) {
			throw new Exception("username should not be empty");
		}
		if (password.length == 0) {
			throw new Exception("password should not be empty");
		}
		users[username] = new User(username, password);
	}
	static User login(string username, string password) {
		if (username !in users || users[username].password != password) {
			throw new Exception("failed to login"); 
		}
		if (username in actives) {
			throw new Exception("Alreday logged in");
		}
		actives[username] = 0; // dummy value
		return users[username];
	}
	static bool isActive(string username) {
		return (username in actives) !is null;
	}
	static User[] getActives() {
		User[] us;
		foreach (name, dummy; actives) {
			us ~= users[name];
		}
		return us;
	}

	this(string username, string password) {
		this.username = username;
		this.password = password;
	}
	void logout() {
		actives.remove(username);
		if (username in waitings) { waitings.remove(username); }
	}
	static Connection getWaiting(string username) {
		if (username in waitings) {
			return waitings[username];
		}
		throw new Exception("user not waiting");
	}
	static User[] getWaitings() {
		User[] us;
		foreach (name, dummy; waitings) {
			us ~= users[name];
		}
		return us;
	}
	void wait(Connection conn) {
		waitings[username] = conn;
	}
	void nonwait() {
		if (username in waitings) { waitings.remove(username); }
	}

	string username;
	string password;
}
class Chatroom {
public:
	Connection a, b;
	this (Connection a, Connection b) {
		this.a = a;
		this.b = b;
	}

	void emit(string s) {
		a.socket.emitln(s);
		b.socket.emitln(s);
	}
	void close() {
		a.close();
		b.close();
	}
}
class Connection {
public:
	enum State {
		HELLO,
		REGISTER_USERNAME,
		REGISTER_PASSWORD,
		LOGIN_USERNAME,
		LOGIN_PASSWORD,
		WAIT_OR_SEARCH,
		SEARCH,
		WAIT,
		CHATTING,
		OTHERWISE
	}
	Socket socket;
	State state;
	string[] databuf;
	User user;
	Chatroom room;

	this(Socket socket) {
		this.socket = socket;
		databuf = [];
		user = null;
	}
	void start() {
		socket.emitln("Hello. Here is a Chat System.");
		trans(State.HELLO);
	}
	void trans(State state) {
		with (State) {
			final switch (state) {
			case HELLO:
				socket.emitln("0: register");
				socket.emitln("1: login");
				socket.emitln("otherwize: exit");
				break;
			case REGISTER_USERNAME, LOGIN_USERNAME:
				socket.emit("username: ");
				break;
			case REGISTER_PASSWORD, LOGIN_PASSWORD:
				socket.emit("password: ");
				break;
			case WAIT:
				user.wait(this);
				break;
			case OTHERWISE:
				break;
			case WAIT_OR_SEARCH:
				socket.emitln("0: wait for ");
				socket.emitln("1: search users");
				break;
			case SEARCH:
				foreach (user; User.getWaitings()) {
					if (user.username != this.user.username) {
						socket.emitln(user.username);
					}
				}
				socket.emit("username for chat: ");
				break;
			case CHATTING:
				socket.emitln("Start chat");
				break;
			}
		}
		this.state = state;
	}
	void startChat(Chatroom room) {
		this.room = room;
		this.trans(State.CHATTING);
		this.user.nonwait();
	}
	void recv(string data) {
		import std.conv;

		if (data.length == 0) { return; }
		with (State) {
			final switch (state) {
			case HELLO:
				int n;
				try {
					n = data.to!int;
				}
				catch(Exception) {
					socket.close();
					return;
				}

				if (n == 0) {
					socket.emitln("-> REGISTER");
					trans(REGISTER_USERNAME);
				} else if (n == 1) {
					socket.emitln("-> LOGIN");
					trans(LOGIN_USERNAME);
				} else {
					socket.emitln("-> GOODBYE");
					trans(OTHERWISE);
				}
				break;
			case REGISTER_USERNAME:
				databuf = [];
				string username = data.dup;
				databuf ~= username;
				trans(REGISTER_PASSWORD);
				break;
			case REGISTER_PASSWORD:
				string password = data.dup;
				auto username = databuf[0];
				try {
					User.register(username, password);
					user = User.login(username, password);
				}
				catch(Exception e) {
					socket.emitln(e.msg);
					trans(REGISTER_USERNAME);
					break;
				}
				socket.emitln("succeeded to login as ", username);
				databuf = [];
				trans(WAIT_OR_SEARCH);
				break;
			case LOGIN_USERNAME:
				string username = data.dup;
				databuf = [];
				databuf ~= username;
				
				trans(LOGIN_PASSWORD);
				break;
			case LOGIN_PASSWORD:
				string password = data.dup;
				auto username = databuf[0];
				databuf = [];
				try {
					user = User.login(username, password);
				}
				catch(Exception e) {
					socket.emitln(e.msg);
					trans(LOGIN_USERNAME);
					break;
				}
				socket.emitln("succeeded to login as ", username);
				trans(WAIT_OR_SEARCH);
				break;
			case WAIT_OR_SEARCH:
				int n = data.to!int;
				if (n == 0) {
					trans(WAIT);
				}
				else if (n == 1) {
					trans(SEARCH);
				}
				else {
					trans(WAIT_OR_SEARCH);
				}
				break;
			case SEARCH:
				string username = data.dup;
				try {
					auto conn = User.getWaiting(username);
					this.room = new Chatroom(this, conn);
					conn.startChat(this.room);
					trans(CHATTING);
				}
				catch(Exception e) {
					socket.emitln(e.msg);
					trans(SEARCH);
					break;
				}
				break;
			case CHATTING:
				room.emit(data);
				break;
			case WAIT:
				break;
			case OTHERWISE:
				socket.close();
				break;
			}
		}
	}
	void close() {
		if (user !is null) {
			user.logout();
		}
		if (room !is null) {
			room.close();
			room = null;
		}
	}
}
Connection[] conns;

void main()
{
	import std.stdio;
	import std.string:strip;
	import std.algorithm:each, sort, remove;

	// start tcp socket as server
	auto server = new TcpSocket();
	server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	server.bind(new InternetAddress(8888));
	server.listen(128);

	auto rset = new SocketSet();
	auto eset = new SocketSet();

	// listen
	while (true) {
		rset.reset();
		rset.add(server);
		conns.each!((c) => rset.add(c.socket));

		eset.reset();
		eset.add(server);
		conns.each!((c) => eset.add(c.socket));

		Socket.select(rset, null, eset);

		if (eset.isSet(server)) {
			// graceful shutdown
			break;
		}

		if (rset.isSet(server)) {
			auto conn = new Connection(server.accept());
			conn.start();
			conns ~= conn;
		}

		ulong[] rmlist;
		foreach (i, conn; conns) {
			if (eset.isSet(conn.socket)) {
				conn.close();
				rmlist ~= i;
				continue;
			}

			if (rset.isSet(conn.socket)) {
				ubyte[1024] buf;
				auto r = conn.socket.receive(buf);
				if (r == 0 || r == Socket.ERROR) { 
					conn.close();
					rmlist ~= i;
					continue;
				}
				conn.recv(buf.asUTF.strip.dup);
			}

			if (! conn.socket.isAlive) {
				conn.close();
				rmlist ~= i;
			}
		}

		foreach (i; rmlist.sort!"a > b") {
			conns = conns.remove(i);
		}
	}
}
