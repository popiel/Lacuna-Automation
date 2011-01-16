#!/usr/bin/perl
#
# This program manages the star database used by glyphinator
# It performs the following functions:
#
#  * Fill star db from probe data
#  * Merge a second db into the main one

use strict;
use warnings;

use DBI;
use List::Util qw(first);
use Getopt::Long;
use Data::Dumper;

use Client;

my %opts;
GetOptions(\%opts,
    'h|help',
    'v|verbose',
    'q|quiet',
    'config=s',
    'db=s',
    'create-db',
    'upgrade',
    'merge-db=s',
    'planet=s@',
    'no-fetch',
);

usage() if $opts{h};

my %do_planets;
if ($opts{planet}) {
    %do_planets = map { normalize_planet($_) => 1 } @{$opts{planet}};
}

my $client = Client->new(
    config => $opts{config} || "config.json",
);

no warnings 'once';
my $db_file = $opts{db} || "./stars.db";
my $star_db;
if (-f $db_file) {
    $star_db = DBI->connect("dbi:SQLite:$db_file")
        or die "Can't open star database $db_file: $DBI::errstr\n";
    $star_db->{RaiseError} = 1;
    $star_db->{PrintError} = 0;

    if ($opts{'upgrade'}) {
        upgrade_star_db();
    } else {
        # Check if db is current, if not, suggest upgrade
        my $ok = eval {
            $star_db->do('select empire_id from orbitals limit 1');
            return 1;
        };
        unless ($ok) {
            die "Database is outdated, please specify --upgrade to continue\n";
        }
    }
} else {
    if ($opts{'create-db'}) {
        $star_db = DBI->connect("dbi:SQLite:$db_file")
            or die "Can't create star database $db_file: $DBI::errstr\n";
        $star_db->{RaiseError} = 1;
        $star_db->{PrintError} = 0;

        for my $sql (create_star_db_sql()) {
            $star_db->do($sql);
        }
        output("$db_file initialized\n");
    } else {
        die "No star database found.  Specify it with --db or use --create-db to create it.\n";
    }
}
$star_db->{AutoCommit} = 0;

if ($opts{'merge-db'}) {
    my $merge_db = DBI->connect("dbi:SQLite:$opts{'merge-db'}")
        or die "Can't open star database $opts{'merge-db'}: $DBI::errstr\n";
    $merge_db->{RaiseError} = 1;
    $merge_db->{PrintError} = 0;

    # Copy stars
    my $get_stars;
    my $ok = eval {
        $get_stars = $merge_db->prepare(q{select *, strftime('%s',last_checked) checked_epoch from stars});
        $get_stars->execute;
        return 1;
    };
    unless ($ok) {
        my $e = $@;
        if ($e =~ /no such column/) {
            output("$opts{'merge-db'} is outdated, it should be upgraded and re-fetched\n");
            $get_stars = $merge_db->prepare(q{select *, 0 checked_epoch from stars});
            $get_stars->execute;

        } else {
            die $e;
        }
    }
    while (my $star = $get_stars->fetchrow_hashref) {
        if (my $row = star_exists($star->{x}, $star->{y})) {
            if ($star->{checked_epoch} > $row->{checked_epoch}) {
                update_star(@{$star}{qw/x y name color zone/})
            }
        } else {
            insert_star(@{$star}{qw/id name x y color zone/});
        }
    }

    # Copy orbitals
    my $get_orbitals;
    $ok = eval {
        $get_orbitals = $merge_db->prepare(q{select *, strftime('%s',last_checked) checked_epoch from orbitals});
        $get_orbitals->execute;
        return 1;
    };
    unless ($ok) {
        my $e = $@;
        if ($e =~ /no such column/) {
            output("$opts{'merge-db'} is outdated, it should be upgraded and re-fetched\n");
            $get_orbitals = $merge_db->prepare(q{select *, 0 checked_epoch from orbitals});
            $get_orbitals->execute;

        } else {
            die $e;
        }
    }
    while (my $orbital = $get_orbitals->fetchrow_hashref) {
        # Check if it exists in the star db, and if so what its type is
        if (my $row = orbital_exists($orbital->{x}, $orbital->{y})) {
            if (($orbital->{checked_epoch}||0) > ($row->{checked_epoch}||0)) {
                update_orbital(@{$orbital}{qw/x y type name empire_id/});
            }
        } else {
            insert_orbital(@{$orbital}{qw/body_id star_id orbit x y type name empire_id/});
        }
    }

    output("$db_file synchronized with $opts{'merge-db'}\n");
}

unless ($opts{'no-fetch'}) {
    my $empire = $client->empire_status;

    # reverse hash, to key by name instead of id
    my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

    # Scan each planet
    for my $planet_name (keys %planets) {
        if (keys %do_planets) {
            next unless $do_planets{normalize_planet($planet_name)};
        }

        verbose("Inspecting $planet_name\n");

        # Load planet data
        my $buildings = $client->body_buildings($planets{$planet_name})->{buildings};

        my $obs = find_observatory($buildings);
        next unless $obs;

        my $stars = $client->get_probed_stars($obs);
        for my $star (@{$stars->{stars}}) {
            if (my $row = star_exists($star->{x}, $star->{y})) {
                if ((($row->{name}||q{}) ne $star->{name})
                        or (($row->{color}||q{}) ne $star->{color})
                        or (($row->{zone}||q{}) ne $star->{zone})) {
                    update_star(@{$star}{qw/x y name color zone/})
                } else {
                    mark_star_checked(@{$row}{qw/x y/});
                }
            } else {
                insert_star(@{$star}{qw/id name x y color zone/});
            }

            if ($star->{bodies} and @{$star->{bodies}}) {
                for my $body (@{$star->{bodies}}) {
                    if (my $row = orbital_exists($body->{x}, $body->{y})) {
                        if ((($row->{type}||q{}) ne $body->{type})
                                or (($row->{name}||q{}) ne $body->{name})
                                or ($body->{empire} and ($row->{empire_id}||q{}) ne $body->{empire}{id})) {
                            update_orbital(@{$body}{qw/x y type name/}, $body->{empire}{id});
                        } else {
                            mark_orbital_checked(@{$body}{qw/x y/});
                        }
                    } else {
                        insert_orbital(@{$body}{qw/id star_id orbit x y type name/}, $body->{empire}{id});
                    }
                }
            }
        }
    }
}

$star_db->commit;

# SQLite can't vacuum in a transaction
verbose("Vacuuming database\n");
$star_db->{AutoCommit} = 1;
$star_db->do('vacuum');

output("$db_file is now up-to-date with your probe data\n");

output("$client->{total_calls} api calls made.\n") if $client->{total_calls};
exit 0;

{
    my $check_star;
    sub star_exists {
        my ($x, $y) = @_;
        $check_star ||= $star_db->prepare(q{select *, strftime('%s',last_checked) checked_epoch from stars where x = ? and y = ?});
        $check_star->execute($x, $y);
        my $row = $check_star->fetchrow_hashref;
        return $row;
    }
}

{
    my $insert_star;
    sub insert_star {
        my ($id, $name, $x, $y, $color, $zone) = @_;

        output("Inserting star $name at $x, $y\n");
        $insert_star ||= $star_db->prepare('insert into stars (id, name, x, y, color, zone) values (?,?,?,?,?,?)');
        $insert_star->execute($id, $name, $x, $y, $color, $zone)
            or die "Can't insert star: " . $insert_star->errstr;
    }
}

{
    my $update_star;
    sub update_star {
        my ($x, $y, $name, $color, $zone) = @_;
        output("Updating star at $x, $y to name $name, color $color, zone $zone\n");
        $update_star ||= $star_db->prepare(q{update stars set last_checked = datetime('now'), name = ?, color = ?, zone = ? where x = ? and y = ?});
        $update_star->execute($name, $color, $zone, $x, $y);
    }
}

{
    my $star_checked;
    sub mark_star_checked {
        my ($x, $y) = @_;
        $star_checked ||= $star_db->prepare(q{update stars set last_checked = datetime('now') where x = ? and y = ?});
        $star_checked->execute($x, $y)
            or die "Can't mark star checked: " . $star_checked->errstr;
    }
}

{
    my $check_orbital;
    sub orbital_exists {
        my ($x, $y) = @_;

        $check_orbital ||= $star_db->prepare(q{select *, strftime('%s',last_checked) checked_epoch from orbitals where x = ? and y = ?});
        $check_orbital->execute($x, $y);
        return $check_orbital->fetchrow_hashref;
    }
}

{
    my $insert_orbital;
    sub insert_orbital {
        my ($id, $star_id, $orbit, $x, $y, $type, $name, $empire) = @_;

        output("Inserting orbital for star $star_id orbit $orbit at $x, $y\n");
        $insert_orbital ||= $star_db->prepare('insert into orbitals (body_id, star_id, orbit, x, y, type, name, empire_id) values (?,?,?,?,?,?,?,?)');
        $insert_orbital->execute($id, $star_id, $orbit, $x, $y, $type, $name, $empire)
            or die "Can't insert orbital: " . $insert_orbital->errstr;
    }
}

{
    my $update_orbital;
    sub update_orbital {
        my ($x, $y, $type, $name, $empire) = @_;

        output(sprintf "Updating orbital at %d, %d to type %s, name %s, empire %s\n", $x, $y, $type, $name, $empire || '[none]');
        $update_orbital ||= $star_db->prepare(q{update orbitals set last_checked = datetime('now'), type = ?, name = ?, empire_id = ? where x = ? and y = ?});
        $update_orbital->execute($type, $name, $empire, $x, $y)
            or die "Can't update orbital: " . $update_orbital->errstr;
    }
}

{
    my $orbital_checked;
    sub mark_orbital_checked {
        my ($x, $y) = @_;
        $orbital_checked ||= $star_db->prepare(q{update orbitals set last_checked = datetime('now') where x = ? and y = ?});
        $orbital_checked->execute($x, $y)
            or die "Can't mark orbital checked: " . $orbital_checked->errstr;
    }
}


sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

sub find_observatory {
    my ($buildings) = @_;

    # Find an Observatory
    my $obs_id = first {
            $buildings->{$_}->{name} eq 'Observatory'
    } keys %$buildings;

    return if not $obs_id;
    return $obs_id;
}


sub create_star_db_sql {
    return
        <<SQL,
CREATE TABLE stars (
    id           int   primary key,
    name         text,
    x            int,
    y            int,
    color        text,
    zone         text,
    last_checked datetime
)
SQL
        <<SQL,
CREATE TABLE orbitals (
    body_id        int,
    star_id        int,
    orbit          int,
    x              int,
    y              int,
    type           text,
    last_excavated datetime,
    name           text,
    empire_id      int,
    last_checked   datetime,
    PRIMARY KEY(star_id, orbit),
    FOREIGN KEY(star_id) REFERENCES stars(id)
)
SQL
        <<SQL,
CREATE INDEX orbital_x_y on orbitals(x,y)
SQL
        <<SQL,
CREATE INDEX zone on stars(zone)
SQL
}

sub upgrade_star_db {
    output("Performing upgrade...");
    my @tests = (
        [
            'select zone from stars limit 1',
            [
                'alter table stars add zone text',
                'create index zone on stars(zone)',
                q{update stars set zone = cast(x/250 as text) || '|' || cast(y/250 as text) where zone is null},
            ],
        ],
        [
            'select name from orbitals limit 1',
            ['alter table orbitals add name text'],
        ],
        [
            'select empire_id from orbitals limit 1',
            ['alter table orbitals add empire_id int'],
        ],
        [
            'select last_checked from orbitals limit 1',
            ['alter table orbitals add last_checked datetime'],
        ],
        [
            'select last_checked from stars limit 1',
            ['alter table stars add last_checked datetime'],
        ],
    );

    check_and_upgrade(@$_) for @tests;
    output("done\n");
}

sub check_and_upgrade {
    my ($check, $upgrade_sql) = @_;

    # Test each new element and migrate as necessary
    my $ok = eval {
        return 0 unless defined $check;
        verbose("Running test SQL: $check\n");
        $star_db->do($check);
        return 1;
    };
    unless ($ok) {
        verbose("Test failed, performing update(s)\n");
        for (@$upgrade_sql) {
            verbose("Running update SQL: $_\n");
            $star_db->do($_);
        }
    }
}

sub usage {
    diag(<<END);
Usage: $0 [options]

Update the stars.db SQLite database for use with glyphinator.pl

Options:
  --verbose              - Be more verbose
  --quiet                - Only print errors
  --config <file>        - Specify a GLC config file, normally lacuna.yml.
  --db <file>            - Specify a star database, normally stars.db.
  --create-db            - Create the star database and initialize the schema.
  --upgrade              - Update database if any schema changes are required.
  --merge-db <file>      - Copy missing data from another database file
  --no-fetch             - Don't fetch probe data, only merge databases
  --planet <name>        - Specify a planet to process.  This option can be
                           passed multiple times to indicate several planets.
                           If this is not specified, all relevant colonies will
                           be inspected.
END
    exit 1;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
}
