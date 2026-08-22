# Queue Consume for Lyrion Music Server

Reproduces the "consume" behavior found in other players (e.g. Music Player Daemon): a track leaves the play queue once it
has finished playing or has been skipped with Next/Previous, but not when you
jump directly to some other track in the queue.

## Use

(Material Skin)

- Server: Settings -> Manage Plugins -> Queue Consume -> Settings:
  - Consume when skipping backwards (off by default)
  - Consume the final track of the queue (on by default)
- Player: Pick the player -> Settings -> Player -> Extra Settings -> Queue Consume -> tick the box.

CLI / JSON-RPC:

    <playerid> queueconsume 1
    <playerid> queueconsume 0
    <playerid> queueconsume ?     -> _queueconsume:0|1

Omitting the value toggles the current setting.

## Troubleshooting

Settings -> Advanced -> Logging, set `plugin.queueconsume` to INFO, then watch
`config/logs/server.log`. Every removal is logged with the queue index and the
reason for the transition.

## Known limits

- Consume plus Repeat is contradictory. Repeat-one is detected and never
  consumes; repeat-all will empty the queue one track per lap.
- If the same file appears twice in the queue and positions have shifted, the
  first matching entry is removed.
- Synced groups are handled at the master player; set the preference on the
  master.

## Installation

Scroll to the end of the "Manage Plugins" page in the LMS WebUI. Find the
"Additional Repositories" and fill the line with the repository address:
https://raw.githubusercontent.com/evb62/lms-plugins/main/public.xml.

Accept the restart prompt, then enable the plugin.
