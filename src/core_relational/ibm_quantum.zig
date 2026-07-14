const std = @import("std");
const http = std.http;

pub const IBMQuantumClient = struct {
    allocator: std.mem.Allocator,
    api_token: []const u8,
    crn: []const u8,
    http_client: http.Client,
    owns_crn: bool,
    backend_name: []const u8,
    owns_backend_name: bool,

    pub fn init(allocator: std.mem.Allocator, api_token: []const u8) !IBMQuantumClient {
        return initWithCrn(allocator, api_token, null, null);
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, api_token: []const u8, backend: []const u8) !IBMQuantumClient {
        return initWithCrn(allocator, api_token, null, backend);
    }

    pub fn initWithCrn(allocator: std.mem.Allocator, api_token: []const u8, crn_override: ?[]const u8, backend_override: ?[]const u8) !IBMQuantumClient {
        const crn = if (crn_override) |value|
            try allocator.dupe(u8, value)
        else if (std.posix.getenv("IBM_QUANTUM_CRN")) |environment_crn|
            try allocator.dupe(u8, environment_crn)
        else
            return error.MissingIBMQuantumCRN;
        errdefer allocator.free(crn);

        const backend = if (backend_override) |value|
            try allocator.dupe(u8, value)
        else if (std.posix.getenv("IBM_QUANTUM_BACKEND")) |environment_backend|
            try allocator.dupe(u8, environment_backend)
        else
            try allocator.dupe(u8, "ibm_brisbane");
        errdefer allocator.free(backend);

        const token = try allocator.dupe(u8, api_token);
        errdefer {
            @memset(token, 0);
            allocator.free(token);
        }

        return .{
            .allocator = allocator,
            .api_token = token,
            .crn = crn,
            .http_client = .{ .allocator = allocator },
            .owns_crn = true,
            .backend_name = backend,
            .owns_backend_name = true,
        };
    }

    pub fn setBackendName(self: *IBMQuantumClient, name: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, name);

        if (self.owns_backend_name) {
            self.allocator.free(self.backend_name);
        }

        self.backend_name = replacement;
        self.owns_backend_name = true;
    }

    pub fn deinit(self: *IBMQuantumClient) void {
        self.zeroSensitiveData();
        self.allocator.free(self.api_token);

        if (self.owns_crn) {
            self.allocator.free(self.crn);
        }

        if (self.owns_backend_name) {
            self.allocator.free(self.backend_name);
        }

        self.http_client.deinit();
        self.* = undefined;
    }

    fn escapeForJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        for (input) |character| {
            switch (character) {
                '"' => try buffer.appendSlice("\\\""),
                '\\' => try buffer.appendSlice("\\\\"),
                '\n' => try buffer.appendSlice("\\n"),
                '\r' => try buffer.appendSlice("\\r"),
                '\t' => try buffer.appendSlice("\\t"),
                '\x08' => try buffer.appendSlice("\\b"),
                '\x0c' => try buffer.appendSlice("\\f"),
                else => {
                    if (character < 0x20) {
                        var escaped: [6]u8 = undefined;
                        const escaped_slice = try std.fmt.bufPrint(
                            &escaped,
                            "\\u00{x:0>2}",
                            .{character},
                        );
                        try buffer.appendSlice(escaped_slice);
                    } else {
                        try buffer.append(character);
                    }
                },
            }
        }

        return buffer.toOwnedSlice();
    }

    fn makeAuthorizationHeader(self: *const IBMQuantumClient, output: []u8) ![]const u8 {
        return std.fmt.bufPrint(output, "Bearer {s}", .{self.api_token});
    }

    fn validateStatus(status: http.Status) !void {
        const status_code = @intFromEnum(status);

        if (status_code < 200 or status_code >= 300) {
            return error.IBMQuantumRequestFailed;
        }
    }

    fn fetchJson(
        self: *IBMQuantumClient,
        method: http.Method,
        uri: std.Uri,
        payload: ?[]const u8,
    ) ![]u8 {
        var authorization_buffer: [4096]u8 = undefined;
        const authorization = try self.makeAuthorizationHeader(&authorization_buffer);

        var response_body = std.ArrayList(u8).init(self.allocator);
        errdefer response_body.deinit();

        var redirect_buffer: [8192]u8 = undefined;

        const result = try self.http_client.fetch(.{
            .method = method,
            .location = .{ .uri = uri },
            .redirect_buffer = &redirect_buffer,
            .response_storage = .{ .dynamic = &response_body },
            .payload = payload,
            .extra_headers = if (payload) |_| &.{
                .{ .name = "authorization", .value = authorization },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/json" },
            } else &.{
                .{ .name = "authorization", .value = authorization },
                .{ .name = "accept", .value = "application/json" },
            },
        });

        try validateStatus(result.status);

        return response_body.toOwnedSlice();
    }

    pub fn submitJob(self: *IBMQuantumClient, qasm: []const u8) ![]u8 {
        return self.submitJobWithBackend(qasm, self.backend_name, 1024);
    }

    pub fn submitJobWithBackend(self: *IBMQuantumClient, qasm: []const u8, backend: []const u8, shots: u32) ![]u8 {
        const uri = try std.Uri.parse("https://cloud.ibm.com/quantum/api/v1/jobs");

        const escaped_qasm = try escapeForJson(self.allocator, qasm);
        defer self.allocator.free(escaped_qasm);

        const escaped_backend = try escapeForJson(self.allocator, backend);
        defer self.allocator.free(escaped_backend);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"qasm\":\"{s}\",\"backend\":\"{s}\",\"shots\":{d}}}",
            .{ escaped_qasm, escaped_backend, shots },
        );
        defer self.allocator.free(payload);

        return self.fetchJson(.POST, uri, payload);
    }

    pub fn getJobResult(self: *IBMQuantumClient, job_id: []const u8) ![]u8 {
        const escaped_job_id = try escapeForJson(self.allocator, job_id);
        defer self.allocator.free(escaped_job_id);

        const uri_string = try std.fmt.allocPrint(
            self.allocator,
            "https://cloud.ibm.com/quantum/api/v1/jobs/{s}",
            .{escaped_job_id},
        );
        defer self.allocator.free(uri_string);

        const uri = try std.Uri.parse(uri_string);

        return self.fetchJson(.GET, uri, null);
    }

    pub fn zeroSensitiveData(self: *IBMQuantumClient) void {
        if (self.api_token.len > 0) {
            @memset(@constCast(self.api_token), 0);
        }

        if (self.crn.len > 0) {
            @memset(@constCast(self.crn), 0);
        }
    }
};

pub const QuantumTaskResult = struct {
    subgraph_id: u64,
    success: bool,
    quantum_states: std.ArrayList(std.math.Complex(f64)),
    correlations: std.ArrayList(f64),
    execution_time_ms: i64,
    backend_name: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, subgraph_id: u64) Self {
        return .{
            .subgraph_id = subgraph_id,
            .success = false,
            .quantum_states = std.ArrayList(std.math.Complex(f64)).init(allocator),
            .correlations = std.ArrayList(f64).init(allocator),
            .execution_time_ms = 0,
            .backend_name = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.quantum_states.deinit();
        self.correlations.deinit();

        if (self.backend_name) |name| {
            self.allocator.free(name);
            self.backend_name = null;
        }

        self.* = undefined;
    }

    pub fn setBackendName(self: *Self, name: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, name);

        if (self.backend_name) |existing_name| {
            self.allocator.free(existing_name);
        }

        self.backend_name = replacement;
    }
};
