param(
    [Parameter(Mandatory = $true)]
    [string]$AppRoot
)

$ErrorActionPreference = "Stop"

function Replace-ExactlyOnce {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Replacement,
        [string]$Description
    )

    $fullPath = (Resolve-Path $Path).Path
    $content = [System.IO.File]::ReadAllText($fullPath)
    $count = 0
    $position = 0

    while (($position = $content.IndexOf($Needle, $position, [System.StringComparison]::Ordinal)) -ge 0) {
        $count++
        $position += $Needle.Length
    }

    if ($count -ne 1) {
        throw "$Description: expected exactly one match, found $count. Refusing to patch an unexpected source tree."
    }

    $updated = $content.Replace($Needle, $Replacement)
    [System.IO.File]::WriteAllText($fullPath, $updated, [System.Text.UTF8Encoding]::new($false))
    Write-Output "PATCH PASS: $Description"
}

$streamRoot = Join-Path $AppRoot "stream-server"
$backendMod = Join-Path $streamRoot "enginefs\src\backend\mod.rs"
$engineFsLib = Join-Path $streamRoot "enginefs\src\lib.rs"
$handleFile = Join-Path $streamRoot "enginefs\src\backend\libtorrent\handle.rs"
$systemFile = Join-Path $streamRoot "server\src\routes\system.rs"
$serverLib = Join-Path $streamRoot "server\src\lib.rs"
$connectorFile = Join-Path $AppRoot "server-connector\src\lib.rs"
$appCargo = Join-Path $AppRoot "Cargo.toml"

# 1) Serializable, bounded diagnostic response types.
$oldBackendFileInfo = @'
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct BackendFileInfo {
    pub name: String,
    pub length: u64,
}
'@

$newBackendFileInfo = @'
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct BackendFileInfo {
    pub name: String,
    pub length: u64,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PieceAvailabilityEntry {
    pub piece_index: i32,
    pub piece_global_offset: u64,
    pub file_overlap_start: u64,
    pub file_overlap_end_exclusive: u64,
    pub request_overlap_start: u64,
    pub request_overlap_end_exclusive: u64,
    pub torrent_has_piece: bool,
    pub reader_ready: bool,
    pub status: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PieceAvailabilitySnapshot {
    pub captured_at_unix_ms: u128,
    pub info_hash: String,
    pub file_index: usize,
    pub file_name: String,
    pub file_size: u64,
    pub file_global_offset: u64,
    pub request_offset: u64,
    pub request_length: u64,
    pub request_global_offset: u64,
    pub piece_length: u64,
    pub first_piece: i32,
    pub last_piece: i32,
    pub storage_mode: String,
    pub piece_count: usize,
    pub torrent_present_bytes: u64,
    pub reader_ready_bytes: u64,
    pub pieces: Vec<PieceAvailabilityEntry>,
}
'@

Replace-ExactlyOnce -Path $backendMod -Needle $oldBackendFileInfo -Replacement $newBackendFileInfo -Description "Add piece availability response models"

# 2) Add a registry lookup that does not refresh last_accessed.
$oldGetEngine = @'
    pub async fn get_engine(&self, info_hash: &str) -> Option<Arc<Engine<B::Handle>>> {
        let engines = self.engines.read().await;
        let engine = engines.get(&info_hash.to_lowercase()).cloned();
        if let Some(engine) = &engine {
            engine.touch();
        }
        engine
    }
'@

$newGetEngine = @'
    pub async fn get_engine(&self, info_hash: &str) -> Option<Arc<Engine<B::Handle>>> {
        let engines = self.engines.read().await;
        let engine = engines.get(&info_hash.to_lowercase()).cloned();
        if let Some(engine) = &engine {
            engine.touch();
        }
        engine
    }

    /// Read-only registry lookup for diagnostics. Unlike get_engine(), this
    /// does not refresh last_accessed or extend the torrent's idle lifetime.
    pub async fn peek_engine(&self, info_hash: &str) -> Option<Arc<Engine<B::Handle>>> {
        let engines = self.engines.read().await;
        engines.get(&info_hash.to_lowercase()).cloned()
    }
'@

Replace-ExactlyOnce -Path $engineFsLib -Needle $oldGetEngine -Replacement $newGetEngine -Description "Add non-touching EngineFS lookup"

# 3) Add a passive piece-range snapshot to the libtorrent handle.
$oldBackendImports = @'
use crate::backend::{
    BackendFileInfo, EngineStats, FileStreamTrait, PieceReadiness, TorrentFilePriorityPlan,
    TorrentHandle as TorrentHandleTrait,
'@

$newBackendImports = @'
use crate::backend::{
    BackendFileInfo, EngineStats, FileStreamTrait, PieceAvailabilityEntry,
    PieceAvailabilitySnapshot, PieceReadiness, TorrentFilePriorityPlan,
    TorrentHandle as TorrentHandleTrait,
'@

Replace-ExactlyOnce -Path $handleFile -Needle $oldBackendImports -Replacement $newBackendImports -Description "Import piece availability models"

$handleMarker = @'
#[async_trait::async_trait]
impl TorrentHandleTrait for LibtorrentTorrentHandle {
'@

$handleAddition = @'
impl LibtorrentTorrentHandle {
    /// Inspect a file-relative byte range without changing priorities, deadlines,
    /// playback leases, or torrent lifecycle. For memory-only mode, reader_ready
    /// mirrors the PieceCacheManager availability check used by stream readiness.
    pub async fn inspect_piece_range(
        &self,
        file_idx: usize,
        offset: u64,
        length: u64,
    ) -> Result<PieceAvailabilitySnapshot> {
        const MAX_RANGE_BYTES: u64 = 64 * 1024 * 1024;
        const MAX_PIECES: u64 = 4096;

        if length == 0 {
            return Err(anyhow!("invalid_range: length must be greater than zero"));
        }
        if length > MAX_RANGE_BYTES {
            return Err(anyhow!(
                "invalid_range: requested range exceeds {} MiB",
                MAX_RANGE_BYTES / (1024 * 1024)
            ));
        }

        let (
            file_name,
            file_size,
            file_global_offset,
            file_first_piece,
            file_last_piece,
            piece_length,
            request_global_offset,
            request_global_end,
            first_piece,
            last_piece,
            piece_presence,
        ) = {
            let session = self.session.read().await;
            let handle = session
                .find_torrent(&self.info_hash)
                .map_err(|error| anyhow!("torrent_unavailable: {}", error))?;

            let files = handle.files();
            if files.is_empty() {
                return Err(anyhow!("metadata_not_ready: torrent file metadata is unavailable"));
            }

            let mut current_offset = 0u64;
            let mut selected_file = None;

            for (index, file) in files.iter().enumerate() {
                let size = u64::try_from(file.size)
                    .map_err(|_| anyhow!("invalid_metadata: negative file size"))?;

                if index == file_idx {
                    selected_file = Some((
                        file.path.to_string(),
                        size,
                        current_offset,
                        file.first_piece,
                        file.last_piece,
                    ));
                }

                current_offset = current_offset
                    .checked_add(size)
                    .ok_or_else(|| anyhow!("invalid_metadata: torrent file offsets overflow"))?;
            }

            let (file_name, file_size, file_global_offset, file_first_piece, file_last_piece) =
                selected_file.ok_or_else(|| anyhow!("file_not_found: file index is out of range"))?;

            let request_end_in_file = offset
                .checked_add(length)
                .ok_or_else(|| anyhow!("invalid_range: offset plus length overflows"))?;

            if file_size == 0 || offset >= file_size || request_end_in_file > file_size {
                return Err(anyhow!(
                    "invalid_range: requested bytes are outside the selected file (size={})",
                    file_size
                ));
            }

            let piece_length = handle.piece_length() as u64;
            if piece_length == 0 {
                return Err(anyhow!("metadata_not_ready: torrent piece length is zero"));
            }

            let request_global_offset = file_global_offset
                .checked_add(offset)
                .ok_or_else(|| anyhow!("invalid_metadata: global request offset overflows"))?;
            let request_global_end = file_global_offset
                .checked_add(request_end_in_file)
                .ok_or_else(|| anyhow!("invalid_metadata: global request end overflows"))?;

            let first_piece_u64 = request_global_offset / piece_length;
            let last_piece_u64 = (request_global_end - 1) / piece_length;
            let first_piece = i32::try_from(first_piece_u64)
                .map_err(|_| anyhow!("invalid_metadata: first piece index is too large"))?;
            let last_piece = i32::try_from(last_piece_u64)
                .map_err(|_| anyhow!("invalid_metadata: last piece index is too large"))?;

            if first_piece < file_first_piece
                || last_piece > file_last_piece
                || last_piece < first_piece
            {
                return Err(anyhow!(
                    "invalid_metadata: requested piece span is outside the file piece range"
                ));
            }

            let piece_count = (last_piece as i64 - first_piece as i64 + 1) as u64;
            if piece_count > MAX_PIECES {
                return Err(anyhow!(
                    "invalid_range: request spans {} pieces; maximum is {}",
                    piece_count,
                    MAX_PIECES
                ));
            }

            let presence = handle.piece_presence(first_piece, last_piece);
            if presence.len() as u64 != piece_count {
                return Err(anyhow!(
                    "availability_unavailable: libtorrent returned {} piece states for {} requested pieces",
                    presence.len(),
                    piece_count
                ));
            }

            (
                file_name,
                file_size,
                file_global_offset,
                file_first_piece,
                file_last_piece,
                piece_length,
                request_global_offset,
                request_global_end,
                first_piece,
                last_piece,
                presence,
            )
        };

        let storage_mode = match self.storage_mode {
            LibtorrentStorageMode::DiskBacked => "disk-backed",
            LibtorrentStorageMode::MemoryOnly => "memory-only",
        }
        .to_string();

        let mut pieces = Vec::new();
        let mut torrent_present_bytes = 0u64;
        let mut reader_ready_bytes = 0u64;

        for (index, piece_index) in (first_piece..=last_piece).enumerate() {
            let torrent_has_piece = piece_presence.get(index).copied().unwrap_or(0) != 0;
            let reader_ready = match self.storage_mode {
                LibtorrentStorageMode::DiskBacked => torrent_has_piece,
                LibtorrentStorageMode::MemoryOnly => {
                    self.piece_cache.has_piece(&self.info_hash, piece_index).await
                }
            };

            let piece_global_offset = (piece_index as u64).saturating_mul(piece_length);
            let piece_global_end = piece_global_offset.saturating_add(piece_length);
            let overlap_start = piece_global_offset.max(request_global_offset);
            let overlap_end = piece_global_end.min(request_global_end);
            let overlap_bytes = overlap_end.saturating_sub(overlap_start);

            if torrent_has_piece {
                torrent_present_bytes = torrent_present_bytes.saturating_add(overlap_bytes);
            }
            if reader_ready {
                reader_ready_bytes = reader_ready_bytes.saturating_add(overlap_bytes);
            }

            let status = if reader_ready {
                "reader-ready"
            } else if torrent_has_piece {
                "downloaded-not-reader-ready"
            } else {
                "not-downloaded"
            };

            pieces.push(PieceAvailabilityEntry {
                piece_index,
                piece_global_offset,
                file_overlap_start: overlap_start.saturating_sub(file_global_offset),
                file_overlap_end_exclusive: overlap_end.saturating_sub(file_global_offset),
                request_overlap_start: overlap_start.saturating_sub(request_global_offset),
                request_overlap_end_exclusive: overlap_end.saturating_sub(request_global_offset),
                torrent_has_piece,
                reader_ready,
                status: status.to_string(),
            });
        }

        let captured_at_unix_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();

        Ok(PieceAvailabilitySnapshot {
            captured_at_unix_ms,
            info_hash: self.info_hash.clone(),
            file_index: file_idx,
            file_name,
            file_size,
            file_global_offset,
            request_offset: offset,
            request_length: length,
            request_global_offset,
            piece_length,
            first_piece,
            last_piece,
            storage_mode,
            piece_count: pieces.len(),
            torrent_present_bytes,
            reader_ready_bytes,
            pieces,
        })
    }
}

#[async_trait::async_trait]
impl TorrentHandleTrait for LibtorrentTorrentHandle {
'@

Replace-ExactlyOnce -Path $handleFile -Needle $handleMarker -Replacement $handleAddition -Description "Add passive libtorrent piece-range inspection"

# 4) Add a loopback endpoint that only looks up an already active torrent.
$systemImportsOld = @'
    extract::{Query, RawQuery, State},
'@
$systemImportsNew = @'
    extract::{Path, Query, RawQuery, State},
'@
Replace-ExactlyOnce -Path $systemFile -Needle $systemImportsOld -Replacement $systemImportsNew -Description "Import diagnostic route path extractor"

$systemHandlerMarker = @'
pub async fn get_engine_stats(
'@

$systemHandlerAddition = @'
#[derive(Debug, serde::Deserialize)]
pub struct PieceAvailabilityParams {
    pub offset: u64,
    pub length: u64,
}

/// Passive diagnostics for an already-managed torrent. This route deliberately
/// does not auto-create torrents and uses peek_engine() so a diagnostic poll
/// cannot keep an idle torrent alive.
pub async fn get_piece_availability(
    State(state): State<AppState>,
    Path((info_hash, file_idx)): Path<(String, usize)>,
    Query(params): Query<PieceAvailabilityParams>,
) -> Response {
    if params.length == 0 || params.length > 64 * 1024 * 1024 {
        return (
            StatusCode::BAD_REQUEST,
            "length must be between 1 byte and 64 MiB",
        )
            .into_response();
    }

    let engine_fs = state.stream_engine();
    let Some(engine) = engine_fs.peek_engine(&info_hash).await else {
        return (
            StatusCode::NOT_FOUND,
            "Torrent is not present in the active stream engine",
        )
            .into_response();
    };

    match engine
        .handle
        .inspect_piece_range(file_idx, params.offset, params.length)
        .await
    {
        Ok(snapshot) => Json(snapshot).into_response(),
        Err(error) => {
            let message = format!("{error:#}");
            let status = if message.starts_with("invalid_range:") {
                StatusCode::BAD_REQUEST
            } else if message.starts_with("file_not_found:") {
                StatusCode::NOT_FOUND
            } else if message.starts_with("metadata_not_ready:") {
                StatusCode::CONFLICT
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            };
            (status, message).into_response()
        }
    }
}

pub async fn get_engine_stats(
'@

Replace-ExactlyOnce -Path $systemFile -Needle $systemHandlerMarker -Replacement $systemHandlerAddition -Description "Add passive piece availability handler"

$routeOld = @'
        .route("/diagnostics/memory", get(diagnostics::memory))
'@
$routeNew = @'
        .route("/diagnostics/memory", get(diagnostics::memory))
        .route(
            "/diagnostics/pieces/{infoHash}/{idx}",
            get(routes::system::get_piece_availability),
        )
'@
Replace-ExactlyOnce -Path $serverLib -Needle $routeOld -Replacement $routeNew -Description "Register piece availability route"

# 5) Preserve the already-validated settings.json fix in the diagnostic build.
$connectorOld = @'
    #[serde(flatten)]
    pub settings: SettingsPayload,
'@
$connectorNew = @'
    #[serde(rename = "values")]
    pub settings: SettingsPayload,
'@
Replace-ExactlyOnce -Path $connectorFile -Needle $connectorOld -Replacement $connectorNew -Description "Preserve settings.json compatibility fix"

# 6) Point the app to the pinned, locally patched stream-server source tree.
$appCargoOld = @'
stream-server = { git = "https://github.com/stremio-native/stream-server.git", rev = "f585ab6eda9b1411034548c131bb0dc30c6f5f9e", package = "server" }
'@
$appCargoNew = @'
stream-server = { path = "stream-server/server", package = "server" }
'@
Replace-ExactlyOnce -Path $appCargo -Needle $appCargoOld -Replacement $appCargoNew -Description "Pin build to locally patched stream-server checkout"

Write-Output "All diagnostic source patches applied successfully."
