
# "Hue Personal Wireless Lighting" is a trademark owned by Koninklijke Philips Electronics N.V.,
# see www.meethue.com for more information.
# I am in no way affiliated with the Philips organization.

# TODO remove unnessesary Functions and Code

package main;

use strict;
use warnings;
use POSIX;
use JSON;
use Data::Dumper;

use HttpUtils;

use IO::Socket::INET;

sub deCONZ_Initialize($)
{
  my ($hash) = @_;

  # Provider
  $hash->{ReadFn}  = "deCONZ_Read";
  $hash->{WriteFn} = "deCONZ_Write";
  $hash->{Clients} = ":deCONZdevice:";

  #Consumer
  $hash->{DefFn}    = "deCONZ_Define";
  $hash->{NotifyFn} = "deCONZ_Notify";
  $hash->{SetFn}    = "deCONZ_Set";
  $hash->{GetFn}    = "deCONZ_Get";
  $hash->{AttrFn}   = "deCONZ_Attr";
  $hash->{UndefFn}  = "deCONZ_Undefine";
  $hash->{AttrList} = "key disable:1 createGroupReadings:1,0 noshutdown:1,0 pollDevices:1,2,0 queryAfterSet:1,0 $readingFnAttributes";
#  $hash->{AttrList} = "key disable:1 disabledForIntervals createGroupReadings:1,0 httpUtils:1,0 noshutdown:1,0 pollDevices:1,2,0 queryAfterSet:1,0 $readingFnAttributes";
}

sub
deCONZ_Read($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $buf;
  my $len = sysread($hash->{CD}, $buf, 10240);
  my $peerhost = $hash->{CD}->peerhost;
  my $peerport = $hash->{CD}->peerport;

  my $close = 0;
  if( !defined($len) || !$len ) {
    $close = 1;

  } elsif( $hash->{websocket} ) {
    $hash->{buf} .= $buf;

    do {
      my $fin = (ord(substr($hash->{buf},0,1)) & 0x80)?1:0;
      my $op = (ord(substr($hash->{buf},0,1)) & 0x0F);
      my $mask = (ord(substr($hash->{buf},1,1)) & 0x80)?1:0;
      my $len = (ord(substr($hash->{buf},1,1)) & 0x7F);
      my $i = 2;
      if( $len == 126 ) {
        $len = unpack( 'n', substr($hash->{buf},$i,2) );
        $i += 2;
      } elsif( $len == 127 ) {
        $len = unpack( 'q', substr($hash->{buf},$i,8) );
        $i += 8;
      }
      if( $mask ) {
        $mask = substr($hash->{buf},$i,4);
        $i += 4;
      }
      #FIXME: hande !$fin
      return if( $len > length($hash->{buf})-$i );

      my $data = substr($hash->{buf}, $i, $len);
      $hash->{buf} = substr($hash->{buf},$i+$len);
      #Log 1, ">>>$data<<<";

      if( $data eq '?' ) {
        #ignore keepalive

      } elsif( $op == 0x01 ) {
        my $obj = eval { decode_json($data) };

        if( $obj ) {
          Log3 $name, 5, "$name: websocket data: ". Dumper $obj;
        } else {
          Log3 $name, 2, "$name: unhandled websocket text $data";

        }

        if( $obj->{t} eq 'event' && $obj->{e} eq 'changed' ) {
          my $code;
          my $id = $obj->{id};
          $code = $name ."-". $id if( $obj->{r} eq 'lights' );
          $code = $name ."-S". $id if( $obj->{r} eq 'sensors' );
          $code = $name ."-G". $id if( $obj->{r} eq 'groups' );
          if( !$code ) {
            Log3 $name, 5, "$name: ignoring event: $code";
            return;
          }

          my $chash = $modules{deCONZdevice}{defptr}{$code};
          if( defined($chash) ) {
            deCONZdevice_Parse($chash,$obj);
            deCONZ_updateGroups($hash, $chash->{ID}) if( !$chash->{helper}{devtype} );
          } else {
            Log3 $name, 4, "$name: message for unknow device received: $code";
          }

        } elsif( $obj->{t} eq 'event' && $obj->{e} eq 'scene-called' ) {
          Log3 $name, 5, "$name: todo: handle websocket scene-called $data";
          # TODO trigger scene event ?

        } elsif( $obj->{t} eq 'event' && $obj->{e} eq 'added' ) {
          Log3 $name, 5, "$name: websocket add: $data";
          deCONZ_Autocreate($hash);

        } elsif( $obj->{t} eq 'event' && $obj->{e} eq 'deleted' ) {
          Log3 $name, 5, "$name: todo: handle websocket delete $data";
          # do what ?
          # TODO should we delete old devices?

        } else {
          Log3 $name, 5, "$name: unknown websocket data: $data";
        }

      } else {
        Log3 $name, 2, "$name: unhandled websocket data: $data";

      }
    } while( $hash->{buf} && !$close );

  } elsif( $buf =~ m'^HTTP/1.1 101 Switching Protocols'i )  {
    $hash->{websocket} = 1;
    #my $buf = plex_msg2hash($buf, 1);
    #Log 1, $buf;

    Log3 $name, 3, "$name: websocket: Switching Protocols ok";

  } else {
    #Log 1, $buf;
    $close = 1;
    Log3 $name, 2, "$name: websocket: Switching Protocols failed";
  }

  if( $close ) {
    deCONZ_closeWebsocket($hash);

    Log3 $name, 2, "$name: websocket closed";
  }
}

sub
deCONZ_Write($@)
{
  my ($hash,$chash,$name,$id,$obj)= @_;

  return deCONZ_Call($hash, $chash, 'groups/' . $1, $obj)  if( $id =~ m/^G(\d.*)/ );

  return deCONZ_Call($hash, $chash, 'sensors/' . $1, $obj) if( $id =~ m/^S(\d.*)/ );

  return deCONZ_Call($hash, $chash, 'lights/' . $id, $obj);
}

sub
deCONZ_Define($$)
{
  my ($hash, $def) = @_;

  my @args = split("[ \t]+", $def);

  return "Usage: define <name> deCONZ <host> [interval]"  if(@args < 3);

  my ($name, $type, $host) = @args;

  ###  if( !defined($host) ) {
  ###    $hash->{NUPNP} = 1;
  ###    deCONZ_Detect($hash);
  ###  } else {
  ###    delete $hash->{NUPNP};
  ###  }

  ###  $interval= 60 unless defined($interval);
  ###  if( $interval < 10 ) { $interval = 10; }

  readingsSingleUpdate($hash, 'state', 'initialized', 1 );

  $hash->{host} = $host;
  ###  $hash->{INTERVAL} = $interval;

  $attr{$name}{"key"} = join "",map { unpack "H*", chr(rand(256)) } 1..16 unless defined( AttrVal($name, "key", undef) );

  $hash->{helper}{last_config_timestamp} = 0;

  if( !defined($hash->{helper}{count}) ) {
    $modules{$hash->{TYPE}}{helper}{count} = 0 if( !defined($modules{$hash->{TYPE}}{helper}{count}) );
    $hash->{helper}{count} =  $modules{$hash->{TYPE}}{helper}{count}++;
  }

  $hash->{NOTIFYDEV} = "global";

  if( $init_done ) {
    deCONZ_OpenDev( $hash ) if( !IsDisabled($name) );
  }

  return undef;
}

sub
deCONZ_Notify($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};

  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if( IsDisabled($name) > 0 ) {
    readingsSingleUpdate($hash, 'state', 'inactive', 1 ) if( ReadingsVal($name,'inactive','' ) ne 'disabled' );
    return undef;
  }

  deCONZ_OpenDev($hash);

  return undef;
}

sub deCONZ_Undefine($$)
{
  my ($hash,$arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub
deCONZ_hash2header($)
{
  my ($hash) = @_;

  return $hash if( ref($hash) ne 'HASH' );

  my $header;
  foreach my $key (keys %{$hash}) {
    #$header .= "\r\n" if( $header );
    $header .= "$key: $hash->{$key}\r\n";
  }

  return $header;
}

sub deCONZ_closeWebsocket($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  delete $hash->{buf};
  delete $hash->{websocket};

  close($hash->{CD}) if( defined($hash->{CD}) );
  delete($hash->{CD});

  delete($selectlist{$name});
  delete($hash->{FD});

  delete($hash->{PORT});
}
sub deCONZ_openWebsocket($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return if( !defined($hash->{websocketport}) );

  deCONZ_closeWebsocket($hash);

  my ($host,undef) = split(':',$hash->{host},2);
  if( my $socket = IO::Socket::INET->new(PeerAddr=>"$host:$hash->{websocketport}", Timeout=>2, Blocking=>1, ReuseAddr=>1) ) {
    $hash->{CD}    = $socket;
    $hash->{FD}    = $socket->fileno();

    $hash->{PORT}  = $socket->sockport if( $socket->sockport );

    $selectlist{$name} = $hash;

    Log3 $name, 3, "$name: websocket opened to $host:$hash->{websocketport}";


    my $ret = "GET ws://$host:$hash->{websocketport} HTTP/1.1\r\n";
    $ret .= deCONZ_hash2header( {                  'Host' => "$host:$hash->{websocketport}",
                                                   'Upgrade' => 'websocket',
                                                'Connection' => 'Upgrade',
                                                    'Pragma' => 'no-cache',
                                             'Cache-Control' => 'no-cache',
                                         'Sec-WebSocket-Key' => 'RkhFTQ==',
                                     'Sec-WebSocket-Version' => '13',
                                   } );

    $ret .= "\r\n";
    #Log 1, $ret;

    syswrite($hash->{CD}, $ret );

  } else {
    Log3 $name, 2, "$name: failed to open websocket";

  }
}

sub deCONZ_fillBridgeInfo($$)
{
  my ($hash,$config) = @_;
  my $name = $hash->{NAME};

  $hash->{name} = $config->{name};
  $hash->{modelid} = $config->{modelid};
  $hash->{swversion} = $config->{swversion};
  $hash->{fwversion} = $config->{fwversion};
  $hash->{apiversion} = $config->{apiversion};
  $hash->{mac} = $config->{mac};

  if( defined($config->{websocketport}) && ($hash->{websocketport} != $config->{websocketport} || !defined($hash->{PORT})) ) {
    $hash->{websocketport} = $config->{websocketport};
    deCONZ_openWebsocket($hash);
  }

  if( $hash->{apiversion} ) {
    my @l = split( '\.', $config->{apiversion} );
    $hash->{helper}{apiversion} = ($l[0] << 16) + ($l[1] << 8) + $l[2];
  }

  if( !defined($config->{'linkbutton'})
      && !defined($attr{$name}{icon}) ) {
    $attr{$name}{icon} = 'hue_filled_bridge_v1' if( $hash->{modelid} && $hash->{modelid} eq 'BSB001' );
    $attr{$name}{icon} = 'hue_filled_bridge_v2' if( $hash->{modelid} && $hash->{modelid} eq 'BSB002' );
  }
}

sub
deCONZ_OpenDev($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  ###deCONZ_Detect($hash) if( defined($hash->{NUPNP}) );

  my ($err,$ret) = HttpUtils_BlockingGet({
    url => "http://$hash->{host}/description.xml",
    method => "GET",
    timeout => 3,
  });

  if( defined($err) && $err ) {
    Log3 $name, 2, "deCONZ_OpenDev: error reading description: ". $err;
  } else {
    Log3 $name, 5, "deCONZ_OpenDev: got description: $ret";
    $ret =~ m/<modelName>([^<]*)/;
    $hash->{modelName} = $1;
    $ret =~ m/<manufacturer>([^<]*)/;
    $hash->{manufacturer} = $1;
  }

  my $result = deCONZ_Call($hash, undef, 'config', undef);
  if( !defined($result) ) {
    Log3 $name, 2, "deCONZ_OpenDev: got empty config";
    return undef;
  }
  Log3 $name, 5, "deCONZ_OpenDev: got config " . Dumper $result;

  if( !defined($result->{'linkbutton'}) || !AttrVal($name, 'key', undef) )
    {
      deCONZ_fillBridgeInfo($hash, $result);

      deCONZ_Pair($hash);
      return;
    }

  

  readingsSingleUpdate($hash, 'state', 'connected', 1 );
  deCONZ_GetUpdate($hash);

  deCONZ_Autocreate($hash);

  return undef;
}

sub deCONZ_Pair($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  readingsSingleUpdate($hash, 'state', 'pairing', 1 );

  my $result = deCONZ_Register($hash);
  if( $result->{'error'} )
    {
      RemoveInternalTimer($hash);
      InternalTimer(gettimeofday()+5, "deCONZ_Pair", $hash, 0);

      return undef;
    }

  $attr{$name}{key} = $result->{success}{username} if( $result->{success}{username} );

  readingsSingleUpdate($hash, 'state', 'paired', 1 );

  deCONZ_OpenDev($hash);

  return undef;
}

sub
deCONZ_string2array($)
{
  my ($lights) = @_;

  my %lights = ();
  foreach my $part ( split(',', $lights) ) {
    my $light = $part;
    $light = $defs{$light}{ID} if( defined $defs{$light} && $defs{$light}{TYPE} eq 'deCONZdevice' );
    if( $light =~ m/^G/ ) {
      my $lights = $defs{$part}->{lights};
      if( $lights ) {
        foreach my $light ( split(',', $lights) ) {
          $lights{$light} = 1;
        }
      }
    } else {
      $lights{$light} = 1;
    }
  }

  my @lights = sort {$a<=>$b} keys(%lights);
  return \@lights;
}

sub
deCONZ_Set($@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my ($arg, @params) = @args;

  $hash->{".triggerUsed"} = 1;

  return "$name: not paired" if( ReadingsVal($name, 'state', '' ) =~ m/^link/ );
  #return "$name: not connected" if( $hash->{STATE} ne 'connected'  );

  # usage check
  if($cmd eq 'statusRequest') {
    return "usage: statusRequest" if( @args != 0 );

    $hash->{LOCAL} = 1;
    #RemoveInternalTimer($hash);
    deCONZ_GetUpdate($hash);
    delete $hash->{LOCAL};
    return undef;

  } elsif($cmd eq 'swupdate') {
    return "usage: swupdate" if( @args != 0 );

    my $obj = {
      'swupdate' => { 'updatestate' => 3, },
    };
    my $result = deCONZ_Call($hash, undef, 'config', $obj);

    if( !defined($result) || $result->{'error'} ) {
      return $result->{'error'}->{'description'};
    }

    $hash->{updatestate} = 3;
    $hash->{helper}{updatestate} = $hash->{updatestate};
    readingsSingleUpdate($hash, 'state', 'updating', 1 );
    return "starting update";

  } elsif($cmd eq 'autocreate') {
    return "usage: autocreate" if( @args != 0 );

    return deCONZ_Autocreate($hash,1);

  } elsif($cmd eq 'autodetect') {
    return "usage: autodetect" if( @args != 0 );

    my $result = deCONZ_Call($hash, undef, 'lights', undef, 'POST');
    return $result->{error}{description} if( $result->{error} );

    return $result->{success}{'/lights'} if( $result->{success} );

    return undef;

  } elsif($cmd eq 'delete') {
    return "usage: delete <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'deCONZdevice' ) {
      $arg = $defs{$arg}{ID};
    }
    return "$arg is not a deCONZ light number" if( $arg !~ m/^\d+$/ );

    my $code = $name ."-". $arg;
    if( defined($modules{deCONZdevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{deCONZdevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    my $result = deCONZ_Call($hash, undef, "lights/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'creategroup') {
    return "usage: creategroup <name> <lights>" if( @args < 2 );

    my $obj = { 'name' => join( ' ', @args[0..@args-2]),
                'lights' => deCONZ_string2array($args[@args-1]),
    };

    my $result = deCONZ_Call($hash, undef, 'groups', $obj, 'POST');
    return $result->{error}{description} if( $result->{error} );

    if( $result->{success} ) {
      deCONZ_Autocreate($hash);

      my $code = $name ."-G". $result->{success}{id};
      return "created $modules{deCONZdevice}{defptr}{$code}->{NAME}" if( defined($modules{deCONZdevice}{defptr}{$code}) );
    }

    return undef;

  } elsif($cmd eq 'deletegroup') {
    return "usage: deletegroup <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'deCONZdevice' ) {
      return "$arg is not a deCONZ group" if( $defs{$arg}{ID} != m/^G/ );
      $defs{$arg}{ID} =~ m/G(.*)/;
      $arg = $1;
    }

    my $code = $name ."-G". $arg;
    if( defined($modules{deCONZdevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{deCONZdevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "$arg is not a deCONZ group number" if( $arg !~ m/^\d+$/ );

    my $result = deCONZ_Call($hash, undef, "groups/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'savescene') {
    my $result;
    if( $hash->{helper}{apiversion} && $hash->{helper}{apiversion} >= (1<<16) + (11<<8) ) {
      return "usage: savescene <name> <lights>" if( @args < 2 );

      my $obj = { 'name' => join( ' ', @args[0..@args-2]),
                  'recycle' => JSON::true,
                  'lights' => deCONZ_string2array($args[@args-1]),
      };

      $result = deCONZ_Call($hash, undef, "scenes", $obj, 'POST');

    } else {
      return "usage: savescene <id> <name> <lights>" if( @args < 3 );

      my $obj = { 'name' => join( ' ', @args[1..@args-2]),
                  'lights' => deCONZ_string2array($args[@args-1]),
      };
      $result = deCONZ_Call($hash, undef, "scenes/$arg", $obj, 'PUT');

    }
    return $result->{error}{description} if( $result->{error} );

    if( $result->{success} ) {
      return "created $result->{success}{id}" if( $result->{success}{id} );
      return "created $arg";
    }

    return undef;

  } elsif($cmd eq 'modifyscene') {
    return "usage: modifyscene <id> <light> <light args>" if( @args < 3 );

    my( $light, @aa ) = @params;
    $light = $defs{$light}{ID} if( defined $defs{$light} && $defs{$light}{TYPE} eq 'deCONZdevice' );

    my %obj;
    if( (my $joined = join(" ", @aa)) =~ /:/ ) {
      my @cmds = split(":", $joined);
      for( my $i = 0; $i <= $#cmds; ++$i ) {
        deCONZdevice_SetParam(undef, \%obj, split(" ", $cmds[$i]) );
      }
    } else {
      my ($cmd, $value, $value2, @a) = @aa;

      deCONZdevice_SetParam(undef, \%obj, $cmd, $value, $value2);
    }

    my $result;
    if( $hash->{helper}{apiversion} && $hash->{helper}{apiversion} >= (1<<16) + (11<<8) ) {
      $result = deCONZ_Call($hash, undef, "scenes/$arg/lightstates/$light", \%obj, 'PUT');
    } else {
      $result = deCONZ_Call($hash, undef, "scenes/$arg/lights/$light/state", \%obj, 'PUT');
    }
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'deletescene') {
    return "usage: deletescene <id>" if( @args != 1 );

    my $result = deCONZ_Call($hash, undef, "scenes/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'scene') {
    return "usage: scene <id>" if( @args != 1 );

    my $obj = { 'scene' => $arg };
    my $result = deCONZ_Call($hash, undef, "groups/0/action", $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+10, "deCONZ_GetUpdate", $hash, 0);

    return undef;

  } elsif($cmd eq 'createrule' || $cmd eq 'updaterule') {
    return "usage: createrule <name> <conditions&actions json>" if( $cmd eq 'createrule' && @args < 2 );
    return "usage: updaterule <id> <conditions&actions json>" if( $cmd eq 'updaterule' && @args != 2 );

    $args[@args-1] = '
{  "name":"Wall Switch Rule",
   "conditions":[
        {"address":"/sensors/1/state/lastupdated","operator":"dx"}
   ],
   "actions":[
        {"address":"/groups/0/action","method":"PUT", "body":{"scene":"S3"}}
]}' if( 0 || !$args[@args-1] );
    my $json = $args[@args-1];
    my $obj = eval { decode_json($json) };
    if( $@ ) {
      Log3 $name, 2, "$name: json error: $@ in $json";
      return undef;
    }

    my $result;
    if( $cmd eq 'updaterule' ) {
     $result = deCONZ_Call($hash, undef, "rules/$args[0]", $obj, 'PUT');
    } else {
     $obj->{name} = join( ' ', @args[0..@args-2]);
     $result = deCONZ_Call($hash, undef, 'rules', $obj, 'POST');
    }
    return $result->{error}{description} if( $result->{error} );

    return "created rule id $result->{success}{id}" if( $result->{success} && $result->{success}{id} );

    return undef;

  } elsif($cmd eq 'deleterule') {
    return "usage: deleterule <id>" if( @args != 1 );
    return "$arg is not a deCONZ rule number" if( $arg !~ m/^\d+$/ );

    my $result = deCONZ_Call($hash, undef, "rules/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'createsensor') {
    return "usage: createsensor <name> <type> <uniqueid> <swversion> <modelid>" if( @args < 5 );

    return "usage: type must be one of: Switch OpenClose Presence Temperature Humidity GenericFlag GenericStatus " if( $args[@args-4] !~ m/Switch|OpenClose|Presence|Temperature|Humidity|Lightlevel|GenericFlag|GenericStatus/ );

    my $obj = { 'name' => join( ' ', @args[0..@args-5]),
                'type' => "CLIP$args[@args-4]",
                'uniqueid' => $args[@args-3],
                'swversion' => $args[@args-2],
                'modelid' => $args[@args-1],
                'manufacturername' => 'FHEM-deCONZ',
              };

    my $result = deCONZ_Call($hash, undef, 'sensors', $obj, 'POST');
    return $result->{error}{description} if( $result->{error} );

    return "created sensor id $result->{success}{id}" if( $result->{success} );

    #    if( $result->{success} ) {
    #      my $code = $name ."-S". $result->{success}{id};
    #      my $devname = "deCONZdevice" . $id;
    #      $devname = $name ."_". $devname if( $hash->{helper}{count} );
    #      my $define = "$devname deCONZdevice sensor $id IODev=$name";
    #
    #      Log3 $name, 4, "$name: create new device '$devname' for address '$id'";
    #
    #      my $cmdret= CommandDefine(undef,$define);
    #
    #      return "created $modules{deCONZdevice}{defptr}{$code}->{NAME}" if( defined($modules{deCONZdevice}{defptr}{$code}) );
    #    }

    return undef;

  } elsif($cmd eq 'deletesensor') {
    return "usage: deletesensor <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'deCONZdevice' ) {
      return "$arg is not a deCONZ sensor" if( $defs{$arg}{ID} !~ m/^S/ );
      $defs{$arg}{ID} =~ m/S(.*)/;
      $arg = $1;
    }

    my $code = $name ."-S". $arg;
    if( defined($modules{deCONZdevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{deCONZdevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "$arg is not a deCONZ sensor number" if( $arg !~ m/^\d+$/ );

    my $result = deCONZ_Call($hash, undef, "sensors/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'configsensor' || $cmd eq 'setsensor' || $cmd eq 'updatesensor') {
    return "usage: $cmd <id> <json>" if( @args < 2 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'deCONZdevice' ) {
      return "$arg is not a deCONZ sensor" if( $defs{$arg}{ID} !~ m/^S/ );
      $defs{$arg}{ID} =~ m/S(.*)/;
      $arg = $1;
    }
    return "$arg is not a deCONZ sensor number" if( $arg !~ m/^\d+$/ );

    my $json = join( ' ', @args[1..@args-1]);
    my $decoded = eval { decode_json($json) };
    if( $@ ) {
      Log3 $name, 2, "$name: json error: $@ in $json";
      return undef;
    }
    $json = $decoded;

    my $endpoint = '';
    $endpoint = 'state' if( $cmd eq 'setsensor' );
    $endpoint = 'config' if( $cmd eq 'configsensor' );

    my $result = deCONZ_Call($hash, undef, "sensors/$arg/$endpoint", $json, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    my $code = $name ."-S". $arg;
    if( my $chash = $modules{deCONZdevice}{defptr}{$code} ) {
      deCONZdevice_GetUpdate($chash);
    }

    return undef;

  } elsif($cmd eq 'deletewhitelist') {
    return "usage: deletewhitelist <key>" if( @args != 1 );

    my $result = deCONZ_Call($hash, undef, "config/whitelist/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'touchlink') {
    return "usage: touchlink" if( @args != 0 );

    my $obj = { 'touchlink' => JSON::true };

    my $result = deCONZ_Call($hash, undef, 'config', $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    return undef if( $result->{success} );

    return undef;

  } elsif($cmd eq 'checkforupdate') {
    return "usage: checkforupdate" if( @args != 0 );

    my $obj = { swupdate => {'checkforupdate' => JSON::true } };

    my $result = deCONZ_Call($hash, undef, 'config', $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    return undef if( $result->{success} );

    return undef;

  } elsif($cmd eq 'active') {
    return "can't activate disabled bridge." if(AttrVal($name, "disable", undef));

    readingsSingleUpdate($hash, 'state', 'active', 1 );
    deCONZ_OpenDev($hash);
    return undef;

  } elsif($cmd eq 'inactive') {
    readingsSingleUpdate($hash, 'state', 'inactive', 1 );
    return undef;

  } else {
    my $list = "active inactive delete creategroup deletegroup savescene deletescene modifyscene scene createrule updaterule deleterule createsensor deletesensor configsensor setsensor updatesensor deletewhitelist touchlink:noArg checkforupdate:noArg autodetect:noArg autocreate:noArg statusRequest:noArg";
    $list .= " swupdate:noArg" if( defined($hash->{updatestate}) && $hash->{updatestate} =~ '^2' );
    return "Unknown argument $cmd, choose one of $list";
  }
}

sub
deCONZ_Get($@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my ($arg, @params) = @args;

  return "$name: not paired" if( ReadingsVal($name, 'state', '' ) =~ m/^link/ );
  #return "$name: not connected" if( $hash->{STATE} ne 'connected'  );
  return "$name: get needs at least one parameter" if( !defined($cmd) );

  # usage check
  if($cmd eq 'devices'
     || $cmd eq 'lights') {
    my $result =  deCONZ_Call($hash, undef, 'lights', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-". $key;
      my $fhem_name ="";
      $fhem_name = $modules{deCONZdevice}{defptr}{$code}->{NAME} if( defined($modules{deCONZdevice}{defptr}{$code}) );
      $ret .= sprintf( "%2i: %-25s %-15s %s\n", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type} );
    }
    $ret = sprintf( "%2s  %-25s %-15s %s\n", "ID", "NAME", "FHEM", "TYPE" ) .$ret if( $ret );
    return $ret;

  } elsif($cmd eq 'groups') {
    my $result =  deCONZ_Call($hash, undef, 'groups', undef);
    return $result->{error}{description} if( $result->{error} );
    $result->{0} = { name => 'Lightset 0', type => 'LightGroup', lights => ["ALL"] };
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-G". $key;
      my $fhem_name ="";
      $fhem_name = $modules{deCONZdevice}{defptr}{$code}->{NAME} if( defined($modules{deCONZdevice}{defptr}{$code}) );
      $result->{$key}{type} = '' if( !defined($result->{$key}{type}) );     #deCONZ fix
      $result->{$key}{class} = '' if( !defined($result->{$key}{class}) );   #deCONZ fix
      $result->{$key}{lights} = [] if( !defined($result->{$key}{lights}) ); #deCONZ fix
      $ret .= sprintf( "%2i: %-15s %-15s %-15s %-15s %s\n", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type}, $result->{$key}{class}, join( ",", @{$result->{$key}{lights}} ) );
    }
    $ret = sprintf( "%2s  %-15s %-15s %-15s %-15s %s\n", "ID", "NAME", "FHEM", "TYPE", "CLASS", "LIGHTS" ) .$ret if( $ret );
    return $ret;

  } elsif($cmd eq 'scenes') {
    my $result =  deCONZ_Call($hash, undef, 'scenes', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a cmp $b} keys %{$result} ) {
      $ret .= sprintf( "%-20s %-20s", $key, $result->{$key}{name} );
      $ret .= sprintf( "%i %i %i %-40s %-20s", $result->{$key}{recycle}, $result->{$key}{locked},$result->{$key}{version}, $result->{$key}{owner}, $result->{$key}{lastupdated}?$result->{$key}{lastupdated}:'' ) if( $arg && $arg eq 'detail' );
      $ret .= sprintf( " %s\n", join( ",", @{$result->{$key}{lights}} ) );
    }
    if( $ret ) {
      my $header = sprintf( "%-20s %-20s", "ID", "NAME" );
      $header .= sprintf( "%s %s %s %-40s %-20s", "R", "L", "V", "OWNER", "LAST UPDATE" ) if( $arg && $arg eq 'detail' );
      $header .= sprintf( " %s\n", "LIGHTS" );
      $ret = $header . $ret;
    }
    return $ret;

  } elsif($cmd eq 'rule') {
    return "usage: rule <id>" if( @args != 1 );
    return "$arg is not a deCONZ rule number" if( $arg !~ m/^\d+$/ );

    my $result =  deCONZ_Call($hash, undef, "rules/$arg", undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = encode_json($result->{conditions}) ."\n". encode_json($result->{actions});
    return $ret;

  } elsif($cmd eq 'rules') {
    my $result =  deCONZ_Call($hash, undef, 'rules', undef);
    return $result->{error}{description} if( $result->{error} );

    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      $ret .= sprintf( "%2i: %-20s", $key, $result->{$key}{name} );
      $ret .= sprintf( " %s", encode_json($result->{$key}{conditions}) ) if( $arg && $arg eq 'detail' );
      $ret .= sprintf( "\n%-24s %s", "", encode_json($result->{$key}{actions}) ) if( $arg && $arg eq 'detail' );
      $ret .= "\n";
    }
    if( $arg && $arg eq 'detail' ) {
      $ret = sprintf( "%2s  %-20s %s\n", "ID", "NAME", "CONDITIONS/ACTIONS" ) .$ret if( $ret );
    } else {
      $ret = sprintf( "%2s  %-20s\n", "ID", "NAME" ) .$ret if( $ret );
    }
    return $ret;

  } elsif($cmd eq 'sensors') {
    my $result =  deCONZ_Call($hash, undef, 'sensors', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-S". $key;
      my $fhem_name ="";
      $fhem_name = $modules{deCONZdevice}{defptr}{$code}->{NAME} if( defined($modules{deCONZdevice}{defptr}{$code}) );
      $ret .= sprintf( "%2i: %-15s %-15s %-20s", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type} );
      $ret .= sprintf( " %s", encode_json($result->{$key}{state}) ) if( $arg && $arg eq 'detail' );
      $ret .= sprintf( "\n%-56s %s", '', encode_json($result->{$key}{config}) ) if( $arg && $arg eq 'detail' );
      $ret .= "\n";
    }
    if( $arg && $arg eq 'detail' ) {
      $ret = sprintf( "%2s  %-15s %-15s %-20s %s\n", "ID", "NAME", "FHEM", "TYPE", "STATE,CONFIG" ) .$ret if( $ret );
    } else {
      $ret = sprintf( "%2s  %-15s %-15s %-20s\n", "ID", "NAME", "FHEM", "TYPE" ) .$ret if( $ret );
    }
    return $ret;

  } elsif($cmd eq 'whitelist') {
    my $result =  deCONZ_Call($hash, undef, 'config', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    my $whitelist = $result->{whitelist};
    foreach my $key ( sort {$whitelist->{$a}{'last use date'} cmp $whitelist->{$b}{'last use date'}} keys %{$whitelist} ) {
      $ret .= sprintf( "%-20s %-20s %-30s %s\n", $whitelist->{$key}{'create date'}, , $whitelist->{$key}{'last use date'}, $whitelist->{$key}{name}, $key );
    }
    $ret = sprintf( "%-20s %-20s %-30s %s\n", "CREATE", "LAST USE", "NAME", "KEY" ) .$ret if( $ret );
    return $ret;

  } else {
    return "Unknown argument $cmd, choose one of lights:noArg groups:noArg scenes:noArg rule rules:noArg sensors:noArg whitelist:noArg";
  }
}

sub
deCONZ_GetUpdate($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  ###  if(!$hash->{LOCAL}) {
  ###    RemoveInternalTimer($hash);
  ###    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "deCONZ_GetUpdate", $hash, 0);
  ###  }

  if( $hash->{websocketport} && !$hash->{PORT} ) {
    deCONZ_openWebsocket($hash);
  }

  my $type;
  my $result;
  my $poll_devices = AttrVal($name, "pollDevices", 1);
  if( $poll_devices ) {
    my ($now) = gettimeofday();
    if( $poll_devices > 1 || $hash->{LOCAL} || $now - $hash->{helper}{last_config_timestamp} > 300 ) {
      $result = deCONZ_Call($hash, $hash, undef, undef);
      $hash->{helper}{last_config_timestamp} = $now;
    } else {
      $type = 'lights';
      $result = deCONZ_Call($hash, $hash, 'lights', undef);
    }
  } else {
    $type = 'config';
    $result = deCONZ_Call($hash, $hash, 'config', undef);
  }

  return undef if( !defined($result) );

  deCONZ_dispatch( {hash=>$hash,chash=>$hash,type=>$type}, undef, undef, $result );

  #deCONZ_Parse($hash, $result);

  return undef;
}

my %dim_values = (
   0 => "dim06%",
   1 => "dim12%",
   2 => "dim18%",
   3 => "dim25%",
   4 => "dim31%",
   5 => "dim37%",
   6 => "dim43%",
   7 => "dim50%",
   8 => "dim56%",
   9 => "dim62%",
  10 => "dim68%",
  11 => "dim75%",
  12 => "dim81%",
  13 => "dim87%",
  14 => "dim93%",
);

sub
deCONZ_updateGroups($$)
{
  my($hash,$lights) = @_;
  my $name = $hash->{NAME};
  my $createGroupReadings = AttrVal($hash->{NAME},"createGroupReadings",undef);
  return if( !defined($createGroupReadings) );
  $createGroupReadings = ($createGroupReadings eq "1");

  my $groups = {};
  foreach my $light ( split(',', $lights) ) {
    foreach my $chash ( values %{$modules{deCONZdevice}{defptr}} ) {
      next if( !$chash->{IODev} );
      next if( !$chash->{lights} );
      next if( $chash->{IODev}{NAME} ne $name );
      next if( $chash->{helper}{devtype} ne 'G' );
      next if( ",$chash->{lights}," !~ m/,$light,/ );
      next if( $createGroupReadings && !AttrVal($chash->{NAME},"createGroupReadings", 1) );
      next if( !$createGroupReadings && !AttrVal($chash->{NAME},"createGroupReadings", undef) );

      $groups->{$chash->{ID}} = $chash;
    }
  }

  foreach my $chash ( values %{$groups} ) {
    my $count = 0;
    my %readings;
    foreach my $light ( split(',', $chash->{lights}) ) {
      next if( !$light );
      my $current = $modules{deCONZdevice}{defptr}{"$name-$light"}{helper};

      next if( !$current );
      next if( $current->{helper}{devtype} );

      $readings{ct} += $current->{ct};
      $readings{bri} += $current->{bri};
      $readings{pct} += $current->{pct};
      $readings{sat} += $current->{sat};

      $readings{on} |= ($current->{on}?'1':'0');
      $readings{reachable} |= ($current->{reachable}?'1':'0');

      if( !defined($readings{alert}) ) {
        $readings{alert} = $current->{alert};
      } elsif( $readings{alert} ne $current->{alert} ) {
        $readings{alert} = "nonuniform";
      }
      if( !defined($readings{colormode}) ) {
        $readings{colormode} = $current->{colormode};
      } elsif( $readings{colormode} ne $current->{colormode} ) {
        $readings{colormode} = "nonuniform";
      }
      if( !defined($readings{effect}) ) {
        $readings{effect} = $current->{effect};
      } elsif( $readings{effect} ne $current->{effect} ) {
        $readings{effect} = "nonuniform";
      }

      ++$count;
    }
    $readings{ct} = int($readings{ct} / $count + 0.5);
    $readings{bri} = int($readings{bri} / $count + 0.5);
    $readings{pct} = int($readings{pct} / $count + 0.5);
    $readings{sat} = int($readings{sat} / $count + 0.5);

    if( $readings{on} ) {
      if( $readings{pct} > 0
          && $readings{pct} < 100  ) {
        $readings{state} = $dim_values{int($readings{pct}/7)};
      }
      $readings{state} = 'off' if( $readings{pct} == 0 );
      $readings{state} = 'on' if( $readings{pct} == 100 );

    } else {
      $readings{pct} = 0;
      $readings{state} = 'off';
    }
    $readings{onoff} =  $readings{on};
    delete $readings{on};

    readingsBeginUpdate($chash);
      foreach my $key ( keys %readings ) {
        if( defined($readings{$key}) ) {
          readingsBulkUpdate($chash, $key, $readings{$key}, 1) if( !defined($chash->{helper}{$key}) || $chash->{helper}{$key} ne $readings{$key} );
          $chash->{helper}{$key} = $readings{$key};
        }
      }
    readingsEndUpdate($chash,1);
  }

}

sub
deCONZ_Parse($$)
{
  my($hash,$config) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "parse status message for $name";
  #Log3 $name, 5, Dumper $config;

  #Log 3, Dumper $config;
  $config = $config->{config} if( defined($config->{config}) );

  deCONZ_fillBridgeInfo($hash, $config);

  $hash->{zigbeechannel} = $config->{zigbeechannel};

  if( my $utc = $config->{UTC} ) {
    substr( $utc, 10, 1, '_' );

    if( my $localtime = $config->{localtime} ) {
      $localtime = TimeNow() if( $localtime eq 'none' );
      substr( $localtime, 10, 1, '_' );

      $hash->{helper}{offsetUTC} = SVG_time_to_sec($localtime) - SVG_time_to_sec($utc);

    } else {
      Log3 $name, 2, "$name: missing localtime configuration";

    }
  }

  if( defined( $config->{swupdate} ) ) {
    my $txt = $config->{swupdate}->{text};
    readingsSingleUpdate($hash, "swupdate", $txt, 1) if( $txt && $txt ne ReadingsVal($name,"swupdate","") );
    if( defined($hash->{updatestate}) ){
      readingsSingleUpdate($hash, 'state', 'update done', 1 ) if( $config->{swupdate}->{updatestate} == 0 &&  $hash->{helper}{updatestate} >= 2 );
      readingsSingleUpdate($hash, 'state', 'update failed', 1 ) if( $config->{swupdate}->{updatestate} == 2 &&  $hash->{helper}{updatestate} == 3 );
    }

    $hash->{updatestate} = $config->{swupdate}->{updatestate};
    $hash->{helper}{updatestate} = $hash->{updatestate};
    if( $config->{swupdate}->{devicetypes} ) {
      my $devicetypes;
      $devicetypes .= 'bridge' if( $config->{swupdate}->{devicetypes}->{bridge} );
      $devicetypes .= ',' if( $devicetypes && scalar(@{$config->{swupdate}->{devicetypes}->{lights}}) );
      $devicetypes .= join( ",", @{$config->{swupdate}->{devicetypes}->{lights}} ) if( $config->{swupdate}->{devicetypes}->{lights} );

      $hash->{updatestate} .= " [$devicetypes]" if( $devicetypes );
    }
  } elsif ( defined(  $hash->{swupdate} ) ) {
    delete( $hash->{updatestate} );
    delete( $hash->{helper}{updatestate} );
  }

  readingsSingleUpdate($hash, 'state', $hash->{READINGS}{state}{VAL}, 0);
}

sub
deCONZ_Autocreate($;$)
{
  my ($hash,$force)= @_;
  my $name = $hash->{NAME};

  if( !$force ) {
    foreach my $d (keys %defs) {
      next if($defs{$d}{TYPE} ne "autocreate");
      return undef if(AttrVal($defs{$d}{NAME},"disable",undef));
    }
  }

  my $autocreated = 0;
  my $result =  deCONZ_Call($hash,undef, 'lights', undef);
  foreach my $key ( keys %{$result} ) {
    my $id= $key;

    my $code = $name ."-". $id;
    if( defined($modules{deCONZdevice}{defptr}{$code}) ) {
      Log3 $name, 5, "$name: id '$id' already defined as '$modules{deCONZdevice}{defptr}{$code}->{NAME}'";
      next;
    }

    my $devname = "deCONZdevice" . $id;
    $devname = $name ."_". $devname if( $hash->{helper}{count} );
    my $define= "$devname deCONZdevice $id IODev=$name";

    Log3 $name, 4, "$name: create new device '$devname' for address '$id'";

    my $cmdret= CommandDefine(undef,$define);
    if($cmdret) {
      Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$id': $cmdret";
    } else {
      $cmdret= CommandAttr(undef,"$devname alias ".$result->{$id}{name});
      $cmdret= CommandAttr(undef,"$devname room deCONZ");
      $cmdret= CommandAttr(undef,"$devname IODev $name");

      deCONZdeviceSetIcon($devname);
      $defs{$devname}{helper}{fromAutocreate} = 1 ;

      $autocreated++;
    }
  }

  $result =  deCONZ_Call($hash,undef, 'groups', undef);
  $result->{0} = { name => "Lightset 0", };
  foreach my $key ( keys %{$result} ) {
    my $id= $key;

    my $code = $name ."-G". $id;
    if( defined($modules{deCONZdevice}{defptr}{$code}) ) {
      Log3 $name, 5, "$name: id '$id' already defined as '$modules{deCONZdevice}{defptr}{$code}->{NAME}'";
      next;
    }

    my $devname= "deCONZGroup" . $id;
    $devname = $name ."_". $devname if( $hash->{helper}{count} );
    my $define= "$devname deCONZdevice group $id IODev=$name";

    Log3 $name, 4, "$name: create new group '$devname' for address '$id'";

    my $cmdret= CommandDefine(undef,$define);
    if($cmdret) {
      Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$id': $cmdret";
    } else {
      $cmdret= CommandAttr(undef,"$devname alias ".$result->{$id}{name});
      $cmdret= CommandAttr(undef,"$devname room deCONZ");
      $cmdret= CommandAttr(undef,"$devname group deCONZGroup");
      $cmdret= CommandAttr(undef,"$devname IODev $name");

      deCONZdeviceSetIcon($devname);
      $defs{$devname}{helper}{fromAutocreate} = 1 ;

      $autocreated++;
    }
  }

  if( $autocreated ) {
    Log3 $name, 2, "$name: autocreated $autocreated devices";
    CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
  }

  return "created $autocreated devices";
}

sub
deCONZ_ProcessResponse($$)
{
  my ($hash,$obj) = @_;
  my $name = $hash->{NAME};

  #Log3 $name, 3, ref($obj);
  #Log3 $name, 3, "Receiving: " . Dumper $obj;

  if( ref($obj) eq 'ARRAY' ) {
    if( defined($obj->[0]->{error})) {
      my $error = $obj->[0]->{error}->{'description'};

      readingsSingleUpdate($hash, 'lastError', $error, 1 );
    }

    if( !AttrVal( $name,'queryAfterSet', 1 ) ) {
      my $successes;
      my $errors;
      my %json = ();
      foreach my $item (@{$obj}) {
        if( my $success = $item->{success} ) {
          next if( ref($success) ne 'HASH' );
          foreach my $key ( keys %{$success} ) {
            my @l = split( '/', $key );
            next if( !$l[1] );
            if( $l[1] eq 'lights' && $l[3] eq 'state' ) {
              $json{$l[2]}->{state}->{$l[4]} = $success->{$key};
              $successes++;

            } elsif( $l[1] eq 'groups' && $l[3] eq 'action' ) {
              my $code = $name ."-G". $l[2];
              my $d = $modules{deCONZdevice}{defptr}{$code};
              if( my $lights = $d->{lights} ) {
                foreach my $light ( split(',', $lights) ) {
                  $json{$light}->{state}->{$l[4]} = $success->{$key};
                  $successes++;
                }
              }
            }
          }

        } elsif( my $error = $item->{error} ) {
          my $msg = $error->{'description'};
          Log3 $name, 3, $msg;
          $errors++;
        }
      }

      my $changed = "";
      foreach my $id ( keys %json ) {
        my $code = $name ."-". $id;
        if( my $chash = $modules{deCONZdevice}{defptr}{$code} ) {
          #$json{$id}->{state}->{reachable} = 1;
          if( deCONZdevice_Parse( $chash, $json{$id} ) ) {
            $changed .= "," if( $changed );
            $changed .= $chash->{ID};
          }
        }
      }
      deCONZ_updateGroups($hash, $changed) if( $changed );
    }

    #return undef if( !$errors && $successes );

    return ($obj->[0]);
  } elsif( ref($obj) eq 'HASH' ) {
    return $obj;
  }

  return undef;
}

sub deCONZ_Register($)
{
  my ($hash) = @_;

  my $obj = {
    'devicetype' => 'fhem',
  };

  if( !$hash->{helper}{apiversion} || $hash->{helper}{apiversion} < (1<<16) + (12<<8) ) {
    $obj->{username} = AttrVal($hash->{NAME}, 'key', '');
  }

  return deCONZ_Call($hash, undef, undef, $obj);
}

#Executes a JSON RPC
sub
deCONZ_Call($$$$;$)
{
  my ($hash,$chash,$path,$obj,$method) = @_;
  my $name = $hash->{NAME};

  if( IsDisabled($name) ) {
    readingsSingleUpdate($hash, 'state', 'inactive', 1 ) if( ReadingsVal($name,'state','' ) ne 'inactive' );
    return undef;
  }

  #Log3 $hash->{NAME}, 5, "Sending: " . Dumper $obj;

  my $json = undef;
  $json = encode_json($obj) if $obj;

  my $url = "http://" . $hash->{host} . "/api";
  my $blocking = 0; # $attr{$name}{httpUtils} < 1;
  $blocking = 1 if( !defined($chash) );
  if( defined($json) ) {
    $method = 'PUT' if( !$method );

    if( ReadingsVal($name, 'state', '') eq 'pairing' ) {
      $method = 'POST';
      $blocking = 1;
    } else {
      $url .= "/" . AttrVal($name, "key", "");
    }
  } else {
    $url .= "/" . AttrVal($name, "key", "");
  }
  $method = 'GET' if( !$method );

  if( defined $path) {
    $url .= "/" . $path;
  }
  #Log3 $name, 3, "Url: " . $url;

  #Log 2, $path;
  if( $blocking ) {
    Log3 $name, 4, "using HttpUtils_BlockingGet: $method ". ($path?$path:'');

    my($err,$data) = HttpUtils_BlockingGet({
      url => $url,
      timeout => 4,
      method => $method,
      noshutdown => AttrVal($name,'noshutdown', 1),
      header => "Content-Type: application/json",
      data => $json,
    });

    if( !$data ) {
      Log3 $name, 2, "$name: empty answer received for $url";
      return undef;
    } elsif( $data =~ m'HTTP/1.1 200 OK' ) {
      Log3 $name, 4, "$name: empty answer received for $url";
      return undef;
    } elsif( $data !~ m/^[\[{].*[\]}]$/ ) {
      Log3 $name, 2, "$name: invalid json detected for $url: $data";
      return undef;
    }

    my $retunjson = eval { decode_json($data) };
    Log3 $name, 2, "$name: json error: $@ in $data" if( $@ );
    return undef if( !$retunjson );

    return deCONZ_ProcessResponse($hash, $retunjson);

  ###    deCONZ_dispatch( {hash=>$hash,chash=>$chash,type=>$path},$err,$data );
  } else {
    Log3 $name, 4, "using HttpUtils_NonblockingGet: $method ". ($path?$path:'');

    my($err,$data) = HttpUtils_NonblockingGet({
      url => $url,
      timeout => 10,
      method => $method,
      noshutdown => AttrVal($name,'noshutdown', 1),
      header => "Content-Type: application/json",
      data => $json,
      hash => $hash,
      chash => $chash,
      type => $path,
      callback => \&deCONZ_dispatch,
    });

    return undef;
  }
}

sub
deCONZ_dispatch($$$;$)
{
  my ($param, $err, $data, $json) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  #Log3 $name, 5, "deCONZ_dispatch";

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data || $json ) {
    if( $data && $data !~ m/^[\[{].*[\]}]$/ ) {
      Log3 $name, 2, "$name: invalid json detected: $data";
      return undef;
    }

    my $queryAfterSet = AttrVal( $name,'queryAfterSet', 1 );

    if( !$json ) {
      $json = eval { decode_json($data) };
      Log3 $name, 2, "$name: json error: $@ in $data" if( $@ );
    }
    return undef if( !$json );

    my $type = $param->{type};

    if( ref($json) eq 'ARRAY' ) {
      deCONZ_ProcessResponse($hash,$json) if( !$queryAfterSet );

      if( defined($json->[0]->{error}))
        {
          my $error = $json->[0]->{error}->{'description'};

          readingsSingleUpdate($hash, 'lastError', $error, 1 );

          Log3 $name, 3, $error;
        }

      #return ($json->[0]);
    }

    if( $hash == $param->{chash} ) {
      if( !defined($type) ) {
        deCONZ_Parse($hash,$json->{config});

        if( defined($json->{sensors}) ) {
          my $sensors = $json->{sensors};
          foreach my $id ( keys %{$sensors} ) {
            my $code = $name ."-S". $id;
            my $chash = $modules{deCONZdevice}{defptr}{$code};

            if( defined($chash) ) {
              deCONZdevice_Parse($chash,$sensors->{$id});
            } else {
              Log3 $name, 4, "$name: message for unknow sensor received: $code";
            }
          }
        }

        if( defined($json->{groups}) ) {
          my $groups = $json->{groups};
          foreach my $id ( keys %{$groups} ) {
            my $code = $name ."-G". $id;
            my $chash = $modules{deCONZdevice}{defptr}{$code};

            if( defined($chash) ) {
              deCONZdevice_Parse($chash,$groups->{$id});
            } else {
              Log3 $name, 2, "$name: message for unknow group received: $code";
            }
          }
        }

        $type = 'lights';
        $json = $json->{lights};
      }

      if( $type eq 'lights' ) {
        my $changed = "";
        my $lights = $json;
        foreach my $id ( keys %{$lights} ) {
          my $code = $name ."-". $id;
          my $chash = $modules{deCONZdevice}{defptr}{$code};

          if( defined($chash) ) {
            if( deCONZdevice_Parse($chash,$lights->{$id}) ) {
              $changed .= "," if( $changed );
              $changed .= $chash->{ID};
            }
          } else {
            Log3 $name, 2, "$name: message for unknow device received: $code";
          }
        }
        deCONZ_updateGroups($hash, $changed) if( $changed );

      } elsif( $type =~ m/^config$/ ) {
        deCONZ_Parse($hash,$json);

      } else {
        Log3 $name, 2, "$name: message for unknow type received: $type";
        Log3 $name, 4, Dumper $json;

      }

    } elsif( $type =~ m/^lights\/(\d*)$/ ) {
      if( deCONZdevice_Parse($param->{chash},$json) ) {
        deCONZ_updateGroups($hash, $param->{chash}{ID});
      }

    } elsif( $type =~ m/^groups\/(\d*)$/ ) {
      deCONZdevice_Parse($param->{chash},$json);

    } elsif( $type =~ m/^sensors\/(\d*)$/ ) {
      deCONZdevice_Parse($param->{chash},$json);

    } elsif( $type =~ m/^lights\/(\d*)\/state$/ ) {
      if( $queryAfterSet ) {
        my $chash = $param->{chash};
        if( $chash->{helper}->{update_timeout} ) {
          RemoveInternalTimer($chash);
          InternalTimer(gettimeofday()+1, "deCONZdevice_GetUpdate", $chash, 0);
        } else {
          RemoveInternalTimer($chash);
          deCONZdevice_GetUpdate( $chash );
        }
      }

    } elsif( $type =~ m/^groups\/(\d*)\/action$/ ) {
      my $chash = $param->{chash};
      if( $chash->{helper}->{update_timeout} ) {
        RemoveInternalTimer($chash);
        InternalTimer(gettimeofday()+1, "deCONZdevice_GetUpdate", $chash, 0);
      } else {
        RemoveInternalTimer($chash);
        deCONZdevice_GetUpdate( $chash );
      }

    } else {
      Log3 $name, 2, "$name: message for unknow type received: $type";
      Log3 $name, 4, Dumper $json;

    }
  }
}

sub
deCONZ_Attr($$$)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;

  my $orig = $attrVal;
  ###  $attrVal = int($attrVal) if($attrName eq "interval");
  ###  $attrVal = 60 if($attrName eq "interval" && $attrVal < 60 && $attrVal != 0);

  if( $attrName eq "disable" ) {
    my $hash = $defs{$name};
    if( $cmd eq 'set' && $attrVal ne "0" ) {
      readingsSingleUpdate($hash, 'state', 'disabled', 1 );
    } else {
      $attr{$name}{$attrName} = 0;
      readingsSingleUpdate($hash, 'state', 'active', 1 );
      deCONZ_OpenDev($hash);
    }
  ###  } elsif( $attrName eq "disabledForIntervals" ) {
  ###    my $hash = $defs{$name};
  ###    if( $cmd eq 'set' ) {
  ###      $attr{$name}{$attrName} = $attrVal;
  ###    } else {
  ###      $attr{$name}{$attrName} = "";
  ###    }
  ###
  ###    readingsSingleUpdate($hash, 'state', IsDisabled($name)?'disabled':'active', 1 );
  ###    deCONZ_OpenDev($hash) if( !IsDisabled($name) );
  ###
  }

  if( $cmd eq 'set' ) {
    if( $orig ne $attrVal ) {
      $attr{$name}{$attrName} = $attrVal;
      return $attrName ." set to ". $attrVal;
    }
  }

  return;
}

1;

=pod
=item summary    module for the deCONZ module
=item summary_DE Modul f&uuml;r das deCONZ module
=begin html

<a name="deCONZ"></a>
<h3>deCONZ</h3>
<ul>
  Module to access the deCONZ module.<br><br>

  I try to support all devices that are supported by the <a href="#deCONZdevice">deCONZdevice</a> API.

  <br><br>
  All newly found devices and groups are autocreated at startup and added to the room deCONZ.

  <br><br>
  Notes:
  <ul>
    <li>This module needs <code>JSON</code>.<br>
        Please install with '<code>cpan install JSON</code>' or your method of choice.</li>
  </ul>


  <br><br>
  <a name="deCONZ_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; deCONZ &lt;host&gt; [&lt;interval&gt;]</code><br>
    <br>

    Defines a deCONZ device with address &lt;host&gt;.<br><br>

    The bridge status will be updated every &lt;interval&gt; seconds. The default and minimum is 60.<br><br>

    After a new bridge is created the pair button on the bridge has to be pressed.<br><br>

    Examples:
    <ul>
      <code>define bridge deCONZ 10.0.1.1</code><br>
    </ul>
  </ul><br>

  <a name="deCONZ_Get"></a>
  <b>Get</b>
  <ul>
    <li>lights<br>
      list the lights known to the bridge.</li>
    <li>groups<br>
      list the groups known to the bridge.</li>
    <li>scenes [detail]<br>
      list the scenes known to the bridge.</li>
    <li>rule &lt;id&gt; <br>
      list the rule with &lt;id&gt;.</li>
    <li>rules [detail] <br>
      list the rules known to the bridge.</li>
    <li>sensors [detail] <br>
      list the sensors known to the bridge.</li>
    <li>whitelist<br>
      list the whitlist of the bridge.</li>
  </ul><br>

  <a name="deCONZ_Set"></a>
  <b>Set</b>
  <ul>
    <li>autocreate<br>
      Create fhem devices for all bridge devices.</li>
    <li>autodetect<br>
      Initiate the detection of new ZigBee devices. After aproximately one minute any newly detected
      devices can be listed with <code>get &lt;bridge&gt; devices</code> and the corresponding fhem devices
      can be created by <code>set &lt;bridge&gt; autocreate</code>.</li>
    <li>delete &lt;name&gt;|&lt;id&gt;<br>
      Deletes the given device in the bridge and deletes the associated fhem device.</li>
    <li>creategroup &lt;name&gt; &lt;lights&gt;<br>
      Create a group out of &lt;lights&gt; in the bridge.
      The lights are given as a comma sparated list of fhem device names or bridge light numbers.</li>
    <li>deletegroup &lt;name&gt;|&lt;id&gt;<br>
      Deletes the given group in the bridge and deletes the associated fhem device.</li>
    <li>savescene &lt;name&gt; &lt;lights&gt;<br>
      Create a scene from the current state of &lt;lights&gt; in the bridge.
      The lights are given as a comma sparated list of fhem device names or bridge light numbers.</li>
    <li>modifyscene &lt;id&gt; &lt;light&gt; &lt;light-args&gt;<br>
      Modifys the given scene in the bridge.</li>
    <li>scene &lt;id&gt;<br>
      Recalls the scene with the given id.</li>
    <li>createrule &lt;name&gt; &lt;conditions&amp;actions json&gt;<br>
      Creates a new rule in the bridge.</li>
    <li>deleterule &lt;id&gt;<br>
      Deletes the given rule in the bridge.</li>
    <li>createsensor &lt;name&gt; &lt;type&gt; &lt;uniqueid&gt; &lt;swversion&gt; &lt;modelid&gt;<br>
      Creates a new CLIP (IP) sensor in the bridge.</li>
    <li>deletesensor &lt;id&gt;<br>
      Deletes the given sensor in the bridge and deletes the associated fhem device.</li>
    <li>configsensor &lt;id&gt; &lt;json&gt;<br>
      Write sensor config data.</li>
    <li>setsensor &lt;id&gt; &lt;json&gt;<br>
      Write CLIP sensor status data.</li>
    <li>updatesensor &lt;id&gt; &lt;json&gt;<br>
      Write sensor toplevel data.</li>
    <li>deletewhitelist &lt;key&gt;<br>
      Deletes the given key from the whitelist in the bridge.</li>
    <li>touchlink<br>
      perform touchlink action</li>
    <li>checkforupdate<br>
      perform checkforupdate action</li>
    <li>statusRequest<br>
      Update bridge status.</li>
    <li>swupdate<br>
      Update bridge firmware. This command is only available if a new firmware is
      available (indicated by updatestate with a value of 2. The version and release date is shown in the reading swupdate.<br>
      A notify of the form <code>define deCONZUpdate notify bridge:swupdate.* {...}</code>
      can be used to be informed about available firmware updates.<br></li>
    <li>inactive<br>
      inactivates the current device. note the slight difference to the
      disable attribute: using set inactive the state is automatically saved
      to the statefile on shutdown, there is no explicit save necesary.<br>
      this command is intended to be used by scripts to temporarily
      deactivate the harmony device.<br>
      the concurrent setting of the disable attribute is not recommended.</li>
    <li>active<br>
      activates the current device (see inactive).</li>
  </ul><br>

  <a name="deCONZ_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#disable">disable</a></li>
    <li><a href="#disabledForIntervals">disabledForIntervals</a></li>
    <li>httpUtils<br>
      0 -> use HttpUtils_BlockingGet<br>
      1 -> use HttpUtils_NonblockingGet<br>
      not set -> use old module specific implementation</li>
    <li>pollDevices<br>
      1 -> the bridge will poll all lights in one go instead of each device polling itself independently<br>
      2 -> the bridge will poll all devices in one go instead of each device polling itself independently<br>
      default is 1.</li>
    <li>createGroupReadings<br>
      create 'artificial' readings for group devices.</li>
      0 -> create readings only for group devices where createGroupReadings ist set to 1
      1 -> create readings for all group devices where createGroupReadings ist not set or set to 1
      undef -> do nothing
    <li>queryAfterSet<br>
      the bridge will request the real device state after a set command. default is 1.</li>
    <li>noshutdown<br>
      Some bridge devcies require a different type of connection handling. raspbee/deconz only works if the connection
      is not immediately closed, the phillips hue bridge now shows the same behavior. so this is now the default.  </li>
  </ul><br>
</ul><br>

=end html
=cut
