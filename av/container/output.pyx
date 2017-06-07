from fractions import Fraction
import logging

from av.container.streams cimport StreamContainer
from av.dictionary cimport _Dictionary
from av.packet cimport Packet
from av.stream cimport Stream, wrap_stream
from av.utils cimport err_check, dict_to_avdict


log = logging.getLogger(__name__)


cdef class OutputContainer(Container):

    def __cinit__(self, *args, **kwargs):
        self.streams = StreamContainer()
        self.metadata = {}

    def __del__(self):
        self.close()

    cpdef add_stream(self, codec_name=None, object rate=None, Stream template=None):
        """add_stream(codec_name, rate=None)

        Create a new stream, and return it.

        :param str codec_name: The name of a codec.
        :param rate: The frame rate for video, and sample rate for audio.
            Examples for video include ``24``, ``23.976``, and
            ``Fraction(30000,1001)``. Examples for audio include ``48000``
            and ``44100``.
        :returns: The new :class:`~av.stream.Stream`.

        """
        
        if (codec_name is None and template is None) or (codec_name is not None and template is not None):
            raise ValueError('needs one of codec_name or template')

        cdef lib.AVCodec *codec
        cdef lib.AVCodecDescriptor *codec_descriptor

        if codec_name is not None:
            codec = lib.avcodec_find_encoder_by_name(codec_name)
            if not codec:
                codec_descriptor = lib.avcodec_descriptor_get_by_name(codec_name)
                if codec_descriptor:
                    codec = lib.avcodec_find_encoder(codec_descriptor.id)
            if not codec:
                raise ValueError("unknown encoding codec: %r" % codec_name)
        else:
            if not template._codec:
                raise ValueError("template has no codec")
            if not template._codec_context:
                raise ValueError("template has no codec context")
            codec = template._codec
        
        # Assert that this format supports the requested codec.
        if not lib.avformat_query_codec(
            self.proxy.ptr.oformat,
            codec.id,
            lib.FF_COMPLIANCE_NORMAL,
        ):
            raise ValueError("%r format does not support %r codec" % (self.format.name, codec_name))

        # Create new stream in the AVFormatContext, set AVCodecContext values.
        # As of last check, avformat_new_stream only calls avcodec_alloc_context3 to create
        # the context, but doesn't modify it in any other way. Ergo, we can allow CodecContext
        # to finish initializing it.
        lib.avformat_new_stream(self.proxy.ptr, codec)
        cdef lib.AVStream *stream = self.proxy.ptr.streams[self.proxy.ptr.nb_streams - 1]
        cdef lib.AVCodecContext *codec_context = stream.codec # For readibility.
        lib.avcodec_get_context_defaults3(stream.codec, codec)
        stream.codec.codec = codec # Still have to manually set this though...

        # Construct the user-land stream so we have access to CodecContext.
        cdef Stream py_stream = wrap_stream(self, stream)
        self.streams.add_stream(py_stream)

        # Copy from the template.
        if template is not None:
            lib.avcodec_copy_context(codec_context, template._codec_context)
            # Reset the codec tag assuming we are remuxing.
            codec_context.codec_tag = 0

        # Now lets set some more sane video defaults
        elif codec.type == lib.AVMEDIA_TYPE_VIDEO:
            codec_context.pix_fmt = lib.AV_PIX_FMT_YUV420P
            codec_context.width = 640
            codec_context.height = 480
            codec_context.bit_rate = 1024000
            codec_context.bit_rate_tolerance = 128000
            codec_context.ticks_per_frame = 1

            rate = Fraction(rate or 24)

            codec_context.framerate.num = rate.numerator
            codec_context.framerate.den = rate.denominator

            stream.time_base = codec_context.time_base

        # Some sane audio defaults
        elif codec.type == lib.AVMEDIA_TYPE_AUDIO:
            codec_context.sample_fmt = codec.sample_fmts[0]
            codec_context.bit_rate = 128000
            codec_context.bit_rate_tolerance = 32000
            codec_context.sample_rate = rate or 48000
            codec_context.channels = 2
            codec_context.channel_layout = lib.AV_CH_LAYOUT_STEREO

        # Some formats want stream headers to be separate
        if self.proxy.ptr.oformat.flags & lib.AVFMT_GLOBALHEADER:
            codec_context.flags |= lib.CODEC_FLAG_GLOBAL_HEADER
        
        return py_stream
    
    cpdef start_encoding(self):
        """Write the file header! Called automatically."""
        
        if self._started:
            return

        used_options = set()

        # Finalize and open all streams.
        cdef Stream stream
        for stream in self.streams:
            
            ctx = stream.codec_context
            if not ctx.is_open:

                ctx.options.update(self.options)
                ctx.open()

                # Track option consumption.
                for k in self.options:
                    if k not in ctx.options:
                        used_options.add(k)

            stream._finalize_for_output()

        # Open the output file, if needed.
        cdef char *name = "" if self.proxy.file is not None else self.name
        if self.proxy.ptr.pb == NULL and not self.proxy.ptr.oformat.flags & lib.AVFMT_NOFILE:
            err_check(lib.avio_open(&self.proxy.ptr.pb, name, lib.AVIO_FLAG_WRITE))

        # Copy the metadata dict.
        dict_to_avdict(&self.proxy.ptr.metadata, self.metadata, clear=True)

        cdef _Dictionary options = self.options.copy()
        self.proxy.err_check(lib.avformat_write_header(
            self.proxy.ptr, 
            &options.ptr
        ))

        # Track option usage...
        for k in self.options:
            if k not in options:
                used_options.add(k)
        # ... and warn if any weren't used.
        # TODO: How to items vs iteritems for Py2 vs 3 in Cython?
        unused_options = {k: v for k, v in self.options.items() if k not in used_options}
        if unused_options:
            log.warning('Some options were not used: %s' % unused_options)

        self._started = True
            
    def close(self, strict=False):

        # Normally, we just ignore that we've already done this.
        if self._done:
            if strict:
                raise ValueError("Already closed.")
            return
        if not self._started:
            if strict:
                raise ValueError("Encoding hasn't started.")
            return

        self.proxy.err_check(lib.av_write_trailer(self.proxy.ptr))
        cdef Stream stream
        for stream in self.streams:
            stream.codec_context.close()
            
        if self.file is None and not self.proxy.ptr.oformat.flags & lib.AVFMT_NOFILE:
            lib.avio_closep(&self.proxy.ptr.pb)

        self._done = True
        
    def mux(self, packets):
        # We accept either a Packet, or a sequence of packets. This should
        # smooth out the transition to the new encode API which returns a
        # sequence of packets.
        if isinstance(packets, Packet):
            self.mux_one(packets)
        else:
            for packet in packets:
                self.mux_one(packet)

    def mux_one(self, Packet packet not None):
        self.start_encoding()

        # Assert the packet is in stream time.
        if packet.struct.stream_index < 0 or packet.struct.stream_index >= self.proxy.ptr.nb_streams:
            raise ValueError('Bad Packet stream_index.')
        cdef lib.AVStream *stream = self.proxy.ptr.streams[packet.struct.stream_index]
        packet._rebase_time(stream.time_base)

        self.proxy.err_check(lib.av_interleaved_write_frame(self.proxy.ptr, &packet.struct))


    