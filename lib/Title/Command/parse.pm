package Title::Command::parse;
use parent Title::Command;

use strict;

use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use File::Basename;
use File::Spec::Functions qw(catfile rel2abs);
use JSON::PP;

use Title::Parser::SRT;
use Title::Parser::VTT;
use Title::Platform::YouTube::Util;
use Title::Recombiner;
use Title::Util::WordWrap;

my $LOCJSON_LINE_LENGTH = 50; # as per LocJSON specs

# special directory name for title config / work files
my $TITLE_DIR_NAME_SUFFIX = '.title';

# name of the config file which resides within TITLE_DIR
my $CONFIG_FILE = 'config.json';

sub get_commands {
    return {
        parse => {
            handler => \&run,
            info => 'Parse source timed text files and generate localization files',
            need_files => 1,
        },
    }
}

sub run {
    my ($self) = @_;

    foreach my $file (@{$self->{files}}) {
        print "\n*** $file ***\n\n";
        $self->run_for_file($file);
    }
}

sub run_for_file {
    my ($self, $fullpath) = @_;

    my ($base_filename, $base_path, $base_suffix) = fileparse($fullpath, qw(.srt .vtt)); # just the file name
    my $filename = $base_filename.$base_suffix;
    $self->{data}->{base_path} = $base_path;
    $self->{data}->{base_filename} = $base_filename;
    $self->{data}->{ext} = $base_suffix;
    $self->{data}->{filename} = $filename;

    my $title_dir = catfile($base_path.$TITLE_DIR_NAME_SUFFIX, $filename);

    if (!-d $title_dir) {
        print "Directory $title_dir not found\n";
        return 1;
    }

    my $config_filename = catfile($title_dir, $CONFIG_FILE);
    if (!-f $config_filename) {
        print "Directory $title_dir doesn't contain a file called $CONFIG_FILE\n";
        return 1;
    }

    print "Reading config file $config_filename\n";

    open(CFG, $config_filename) or die $!;
    binmode(CFG);
    my $config = decode_json(join('', <CFG>));
    close(CFG);

    print "Reading source file $fullpath\n";

    open(IN, $fullpath) or die $!;
    binmode(IN, ':utf8');
    my $raw_contents = join('', <IN>);
    close(IN);

    my $chunks;

    if ($self->{data}->{ext} eq '.srt') {
        $chunks = Title::Parser::SRT::parse($raw_contents);
    } elsif ($self->{data}->{ext} eq '.vtt') {
        $chunks = Title::Parser::VTT::parse($raw_contents);
    } else {
        print "Unknown file type for '$filename'";
        return 1;
    }

    # create a .meta document from the original (not recombined) chunks

    my @meta = ();
    map {
        my $text = $_->{text};

        push @meta, {
            from => $_->{from},
            till => $_->{till},
            hash => md5_hex(encode_utf8($text))
        };
    } @$chunks;

    # now recombine the chunks for localization

    $chunks = Title::Recombiner::combine($chunks);

    #print Dumper(\@meta);

    my $meta_filename = catfile($title_dir, $base_filename.'.meta');
    print "Saving meta output to $meta_filename\n";
    open OUT, ">$meta_filename" or die $!;
    binmode OUT;
    print OUT make_json_encoder()->utf8->encode(\@meta);
    close OUT;

    # generate keys and comments for each chunk

    map {
        my $from_segment = $_->{from_segment};
        my $till_segment = $_->{till_segment};

        my @comments = ();
        my $key;

        if ($from_segment == $till_segment) {
            push @comments, "Segment $from_segment";
            $key = $from_segment;
        } else {
            push @comments, "Segments $from_segment through $till_segment";
            $key = "$from_segment-$till_segment";
        }

        if ($config->{platform} eq 'Vimeo' && $config->{videoId} ne '') {
            push @comments, Title::Platform::Vimeo::Util::generate_preview_link(
                $config->{videoId}, $_->{from}, $_->{till}
            );
        }

        if ($config->{platform} eq 'YouTube' && $config->{videoId} ne '') {
            push @comments, Title::Platform::YouTube::Util::generate_preview_link(
                $config->{videoId}, $_->{from}, $_->{till}
            );
        }

        $_->{key} = $key;
        $_->{comments} = \@comments;
    } @$chunks;

    ######################
    #print Dumper($chunks);
    #exit;
    ######################

    # generate locjson

    my $units = [];
    map {
        my @lines = wrap($_->{text}, $LOCJSON_LINE_LENGTH);
        push @$units, {
            key => $_->{key},
            properties => {
                comments => $_->{comments},
            },
            source => \@lines
        };
    } @$chunks;

    my $locjson = {
        properties => {
            comments => [
                'Source file was generated automatically by Title'
            ]
        },
        units => $units
    };

    if (exists $config->{locjsonFileComments}) {
        push(@{$locjson->{properties}->{comments}}, @{$config->{locjsonFileComments}});
    }

    #######
    #print make_json_encoder()->encode($locjson);
    #exit;
    #######

    my $locjson_filename = catfile($title_dir, $base_filename.'.locjson');
    print "Saving localization file to $locjson_filename\n";
    open OUT, ">$locjson_filename" or die $!;
    binmode OUT;
    print OUT make_json_encoder()->utf8->encode($locjson);
    close OUT;

    return 0;
}

sub make_json_encoder {
    return JSON::PP->new->
    indent(1)->indent_length(4)->space_before(0)->space_after(1)->
    escape_slash(0)->canonical;
}

1;