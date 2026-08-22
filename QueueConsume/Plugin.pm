package Plugins::QueueConsume::Plugin;

# Queue Consume for Lyrion Music Server.
#
# Reproduces MPD's "consume" behaviour: a track leaves the play queue once it
# has finished playing or has been skipped with Next/Previous, but NOT when
# you jump directly to some other track in the queue.
#
# Per-player enabling lives in Settings -> Player -> Extra Settings -> Queue
# Consume; the two global options (consume on Previous, consume the final
# track) live on the plugin's server-wide settings page, reachable from the
# "Settings" link in Manage Plugins.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);

use Slim::Control::Request;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::QueueConsume::Settings;
use Plugins::QueueConsume::PlayerSettings;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.queueconsume',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_QUEUECONSUME',
});

# Server-wide preferences; the per-player "consume" flag is read via
# $prefs->client($client).
my $prefs = preferences('plugin.queueconsume');

# Runtime state, keyed on the master player's id:
#   index  - queue position of the track we consider "currently playing"
#   url    - its url, used to re-locate it if the queue shifted under us
#   jump   - how we got to the current track: absolute | next | prev
#   busy   - re-entrancy guard while we delete something ourselves
my %state;

# Slim::Player::Playlist::track() on current LMS, song() on older builds.
my $TRACK_AT = Slim::Player::Playlist->can('track') || Slim::Player::Playlist->can('song');

sub getDisplayName { 'PLUGIN_QUEUECONSUME' }

sub initPlugin {
	my $class = shift;

	$prefs->init({
		consume           => 0,   # per-player flag, default off
		consumeOnPrevious => 0,   # global: also consume when skipping backwards
		consumeLastTrack  => 1,   # global: consume the final track of the queue
	});

	if (main::WEBUI) {
		Plugins::QueueConsume::Settings->new;
		Plugins::QueueConsume::PlayerSettings->new;
	}

	# Track queue mutations so we can consume the track we moved away from.
	Slim::Control::Request::subscribe(
		\&_playlistCallback,
		[ ['playlist'],
		  ['newsong', 'jump', 'index', 'stop', 'clear', 'load', 'loadtracks',
		   'addtracks', 'inserttracks', 'delete', 'move', 'sync'] ]
	);

	# Transport commands are only logged here for diagnostics: the final
	# track is consumed whenever the queue stops on it, whether the stop
	# came from the user or from the queue running out.
	Slim::Control::Request::subscribe(
		\&_transportCallback,
		[ ['stop', 'pause', 'power', 'playlistcontrol', 'play'] ]
	);

	# CLI / JSON-RPC:  <playerid> queueconsume <0|1>   and   <playerid> queueconsume ?
	Slim::Control::Request::addDispatch(['queueconsume', '_newvalue'], [1, 1, 1, \&_consumeCommand]);

	$class->SUPER::initPlugin(@_);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_playlistCallback);
	Slim::Control::Request::unsubscribe(\&_transportCallback);
	%state = ();
}

# Cleanup hook: drop the plugin's preferences when LMS uninstalls it.
sub uninstallPlugin {
	main::INFOLOG && $log->is_info && $log->info('QueueConsume: removing preferences on uninstall');

	if ($prefs) {
		eval { $prefs->remove() };
		$log->error("Failed to remove preferences: $@") if $@;
	}

	return 1;
}

# ---------------------------------------------------------------- callbacks --

sub _playlistCallback {
	my $request = shift;

	my $client = $request->client() || return;
	$client = $client->master();

	my $cmd = $request->getRequest(1) || return;
	my $st  = $state{$client->id} ||= {};

	if ($cmd eq 'jump' || $cmd eq 'index') {
		my $index = $request->getParam('_index');
		$index = '' unless defined $index;
		$index =~ s/^\s+//;

		# Classify how the user moved: relative jumps (Next/Previous) vs an
		# explicit queue position (the track jumped away from stays in place).
		if ($index =~ /^(?:\+|%2B)/i) {
			$st->{jump} = 'next';
		}
		elsif ($index =~ /^-/) {
			$st->{jump} = 'prev';
		}
		else {
			$st->{jump} = 'absolute';
		}

		main::DEBUGLOG && $log->is_debug && $log->debug(
			$client->id . ": jump/index cmd, _index='$index', classified as '$st->{jump}'"
		);

		return;
	}

	if ($cmd eq 'newsong') {
		_songChanged($client);
		return;
	}

	if ($cmd eq 'stop') {
		_maybeConsumeLast($client);
		return;
	}

	# Any other queue mutation: just refresh our idea of what is playing.
	_sync($client);
}

sub _transportCallback {
	my $request = shift;

	my $client = $request->client() || return;
	$client = $client->master();

	# Diagnostic only: record which transport commands arrive around the
	# end of a queue. No state is changed here.
	main::DEBUGLOG && $log->is_debug && $log->debug(
		$client->id . ": transport command '" . $request->getRequest(0) . "'"
	);
}

# ------------------------------------------------------------------- logic --

sub _songChanged {
	my $client = shift;
	my $st = $state{$client->id} ||= {};

	return if $st->{busy};

	my $jump      = delete $st->{jump};
	my $prevIndex = $st->{index};
	my $prevUrl   = $st->{url};

	my $consume = 1;

	$consume = 0 unless defined $prevIndex;
	$consume = 0 unless $prefs->client($client)->get('consume');
	$consume = 0 if $jump && $jump eq 'absolute';
	$consume = 0 if $jump && $jump eq 'prev' && !$prefs->get('consumeOnPrevious');

	# Repeat-one, or a restart of the same entry: never eat what is playing now.
	my $nowIndex = Slim::Player::Source::playingSongIndex($client);
	$consume = 0 if defined $nowIndex && defined $prevIndex && $nowIndex == $prevIndex;

	if ($consume) {
		main::INFOLOG && $log->is_info && $log->info(
			$client->id . ": consuming index $prevIndex (jump=" . ($jump || 'natural') . ")"
		);

		$st->{busy} = 1;
		_removeTrack($client, $prevIndex, $prevUrl);
		$st->{busy} = 0;
	}

	_sync($client);
}

# Playback stopped. When the queue ran out naturally (we are sitting on the
# last entry), consume that final track so the queue ends up empty.
#
# The removal is immediate, no deferred timer: a natural end of queue only
# ever produces ['playlist','stop'].
sub _maybeConsumeLast {
	my $client = shift;
	my $st = $state{$client->id} ||= {};

	if ($st->{busy}) {
		main::DEBUGLOG && $log->is_debug && $log->debug($client->id . ": skip - busy");
		return;
	}

	if (!$prefs->get('consumeLastTrack')) {
		main::DEBUGLOG && $log->is_debug && $log->debug($client->id . ": skip - consumeLastTrack off");
		return;
	}

	if (!$prefs->client($client)->get('consume')) {
		main::DEBUGLOG && $log->is_debug && $log->debug($client->id . ": skip - player consume off");
		return;
	}

	if (!defined $st->{index}) {
		main::DEBUGLOG && $log->is_debug && $log->debug($client->id . ": skip - no tracked index");
		return;
	}

	my $count = Slim::Player::Playlist::count($client) || 0;
	if (!$count || $st->{index} != $count - 1) {
		main::DEBUGLOG && $log->is_debug && $log->debug(
			$client->id . ": skip - not on last track (index=$st->{index}, count=$count)"
		);
		return;
	}

	my ($index, $url) = ($st->{index}, $st->{url});
	delete $st->{index};
	delete $st->{url};

	main::INFOLOG && $log->is_info && $log->info(
		$client->id . ": queue ended on the final track - consuming index $index"
	);

	$st->{busy} = 1;
	_removeTrack($client, $index, $url, 1);
	$st->{busy} = 0;
}

sub _removeTrack {
	my ($client, $index, $url, $force) = @_;

	my $count = Slim::Player::Playlist::count($client) || 0;
	return unless $count;

	# The queue may have shifted since we recorded this position: re-locate
	# the recorded url and bail out if it is gone.
	if (defined $url) {
		my $at = _urlAt($client, $index);
		if (!defined $at || $at ne $url) {
			$index = _findUrl($client, $url);
			return unless defined $index;
		}
	}

	return if !defined $index || $index < 0 || $index >= $count;

	# Unless forced (final-track consumption), never remove what is playing.
	unless ($force) {
		my $now = Slim::Player::Source::playingSongIndex($client);
		return if defined $now && $now == $index;
	}

	$client->execute(['playlist', 'delete', $index]);
}

sub _sync {
	my $client = shift;
	my $st = $state{$client->id} ||= {};

	my $count = Slim::Player::Playlist::count($client) || 0;
	my $index = $count ? Slim::Player::Source::playingSongIndex($client) : undef;

	if (defined $index && $index >= 0 && $index < $count) {
		$st->{index} = $index;
		$st->{url}   = _urlAt($client, $index);
	}
	else {
		delete $st->{index};
		delete $st->{url};
	}
}

sub _urlAt {
	my ($client, $index) = @_;

	return unless $TRACK_AT && defined $index;

	my $obj = eval { $TRACK_AT->($client, $index) };
	return unless defined $obj;

	return blessed($obj) ? $obj->url : "$obj";
}

sub _findUrl {
	my ($client, $url) = @_;

	my $count = Slim::Player::Playlist::count($client) || 0;

	for my $i (0 .. $count - 1) {
		my $at = _urlAt($client, $i);
		return $i if defined $at && $at eq $url;
	}

	return;
}

# ---------------------------------------------------------------------- CLI --

# Handles both the command (<playerid> queueconsume <0|1>) and the query
# (<playerid> queueconsume ?).
sub _consumeCommand {
	my $request = shift;

	if ($request->isNotCommand([['queueconsume']]) && $request->isNotQuery([['queueconsume']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client = $request->client();
	if (!$client) {
		$request->setStatusBadDispatch();
		return;
	}
	$client = $client->master();

	my $cprefs = $prefs->client($client);

	if ($request->isQuery([['queueconsume']])) {
		$request->addResult('_queueconsume', $cprefs->get('consume') ? 1 : 0);
		$request->setStatusDone();
		return;
	}

	# Without a value, toggle the current setting.
	my $newvalue = $request->getParam('_newvalue');
	$newvalue = $cprefs->get('consume') ? 0 : 1 unless defined $newvalue;

	$cprefs->set('consume', $newvalue ? 1 : 0);
	_sync($client);

	$request->setStatusDone();
}

1;
