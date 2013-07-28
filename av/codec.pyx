from cpython.oldbuffer cimport PyBuffer_FromMemory
from cpython cimport array

cimport libav as lib

cimport av.format
from .utils cimport err_check

cdef int pyav_get_buffer(lib.AVCodecContext *ctx, lib.AVFrame *frame):
    
    # Get the buffer the way it would normally get it
    cdef int ret
    ret = lib.avcodec_default_get_buffer(ctx, frame)
    
    # Allocate a PacketInfo and copy the current cur_pkt_info stored in 
    # AVCodecContext.opaque, which is a pointer to Codec.cur_pkt_info.
    # Codec.cur_pkt_info should be set in the decode method of format.Stream.
    # this is done so the new AVFrame can store this pts and dts of the first packet
    # needed to create it. This is need for timing purposes see
    # http://dranger.com/ffmpeg/tutorial05.html. this is the done the same way but
    # we use AVCodecContext.opaque so we don't need a global variable.
    
    # Allocate a new PacketInfo to be stored in AVFrame
    cdef PacketInfo *pkt_info = <PacketInfo*>lib.av_malloc(sizeof(PacketInfo))
    
    # Get the PacketInfo of the Current packet thats is being decoded
    cdef PacketInfo *cur_pkt_info = <PacketInfo*> ctx.opaque
    
    # Copy PacketInfo
    pkt_info[0] = cur_pkt_info[0]
    
    # Assign AVFrame.opaque pointer to new PacketInfo
    frame.opaque = pkt_info
    
    #return the result of avcodec_default_get_buffer
    return ret

cdef void pyav_release_buffer(lib.AVCodecContext *ctx, lib.AVFrame *frame):
    if frame:
        #Free AVFrame PacketInfo
        lib.av_freep(&frame.opaque)

    lib.avcodec_default_release_buffer(ctx, frame)


cdef class Codec(object):
    
    def __init__(self, av.format.Stream stream):
        
        # Our pointer.
        self.ctx = stream.ptr.codec
        
        # Keep these pointer alive with this reference.
        self.format_ctx = stream.ctx_proxy
        
        if stream.type == 'attachment':
            return
        
        # Find the decoder.
        # We don't need to free this later since it is a static part of the lib.
        self.ptr = lib.avcodec_find_decoder(self.ctx.codec_id)
        if self.ptr == NULL:
            return
        
        # Open the codec.
        try:
            err_check(lib.avcodec_open2(self.ctx, self.ptr, &self.options))
        except:
            # Signal that we don't need to close it.
            self.ptr = NULL
            raise
        
        # Setup cur_pkt_info
        self.cur_pkt_info.pts = lib.AV_NOPTS_VALUE
        self.cur_pkt_info.dts = lib.AV_NOPTS_VALUE
        
        # Point CodecConext.opaque ot self.cur_pkt_info.pts
        # so pyav_release_buffer get cur_pkt_info
        
        self.ctx.opaque = &self.cur_pkt_info
        
        # Override the codec get_buffer and relase_buffer with our own
        # custom functions that will store self.cur_pkt_info in the AVFrame.
        
        self.ctx.get_buffer = pyav_get_buffer
        self.ctx.release_buffer = pyav_release_buffer
    
    def __dealloc__(self):
        if self.ptr != NULL:
            lib.avcodec_close(self.ctx);
        if self.options != NULL:
            lib.av_dict_free(&self.options)
    
    property name:
        def __get__(self): return bytes(self.ptr.name) if self.ptr else None
    property long_name:
        def __get__(self): return bytes(self.ptr.long_name) if self.ptr else None
    

cdef class Packet(object):
    
    """A packet of encoded data within a :class:`~av.format.Stream`.

    This may, or may not include a complete object within a stream.
    :meth:`decode` must be called to extract encoded data.

    """
    def __init__(self):
        lib.av_init_packet(&self.struct)
        self.is_null = False

    def __dealloc__(self):
        lib.av_free_packet(&self.struct)
    
    def __repr__(self):
        return '<%s.%s of %s at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.stream,
            id(self),
        )
    
    def decode(self):
        """Decode the data in this packet.

       yields frame.
       
       Note.
       Some codecs will cause frames to be buffered up in the decoding process. If Packets Data
       is NULL and size is 0 the packet will try and retrieve those frames. Context.demux will 
       yeild a NULL Packet as its last packet.
        """

        if not self.struct.data:
            while True:
                frame = self.stream.decode(self)
                if frame:
                    yield frame
                else:
                    break
        else:
            frame = self.stream.decode(self)
            if frame:
                yield frame
                
    property pts:
        def __get__(self): return self.struct.pts
    property dts:
        def __get__(self): return self.struct.dts 
    property size:
        def __get__(self): return self.struct.size
    property duration:
        def __get__(self): return self.struct.duration
    
    property best_ts:
        def __get__(self):
            if self.pts == lib.AV_NOPTS_VALUE:
                return self.dts
            return self.pts


cdef class SubtitleProxy(object):
    def __dealloc__(self):
        lib.avsubtitle_free(&self.struct)


cdef class Subtitle(object):
    
    def __init__(self, Packet packet, SubtitleProxy proxy):
        self.packet = packet
        self.proxy = proxy
        cdef int i
        self.rects = tuple(SubtitleRect(self, i) for i in range(self.proxy.struct.num_rects))
    
    def __repr__(self):
        return '<%s.%s of %s at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.packet.stream,
            id(self),
        )
    
    property format:
        def __get__(self): return self.proxy.struct.format
    property start_display_time:
        def __get__(self): return self.proxy.struct.start_display_time
    property end_display_time:
        def __get__(self): return self.proxy.struct.end_display_time
    property pts:
        def __get__(self): return self.proxy.struct.pts


cdef class SubtitleRect(object):

    def __init__(self, Subtitle subtitle, int index):
        if index < 0 or index >= subtitle.proxy.struct.num_rects:
            raise ValueError('subtitle rect index out of range')
        self.proxy = subtitle.proxy
        self.ptr = self.proxy.struct.rects[index]
        
        if self.ptr.type == lib.SUBTITLE_NONE:
            self.type = b'none'
        elif self.ptr.type == lib.SUBTITLE_BITMAP:
            self.type = b'bitmap'
        elif self.ptr.type == lib.SUBTITLE_TEXT:
            self.type = b'text'
        elif self.ptr.type == lib.SUBTITLE_ASS:
            self.type = b'ass'
        else:
            raise ValueError('unknown subtitle type %r' % self.ptr.type)
    
    def __repr__(self):
        return '<%s.%s %s %dx%d at %d,%d; at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.type,
            self.width,
            self.height,
            self.x,
            self.y,
            id(self),
        )
    
    property x:
        def __get__(self): return self.ptr.x
    property y:
        def __get__(self): return self.ptr.y
    property width:
        def __get__(self): return self.ptr.w
    property height:
        def __get__(self): return self.ptr.h
    property nb_colors:
        def __get__(self): return self.ptr.nb_colors
    property text:
        def __get__(self): return self.ptr.text
        
    property ass:
        def __get__(self): return self.ptr.ass

    property pict_line_sizes:
        def __get__(self):
            if self.ptr.type != lib.SUBTITLE_BITMAP:
                return ()
            else:
                # return self.ptr.nb_colors
                return tuple(self.ptr.pict.linesize[i] for i in range(4))
    
    property pict_buffers:
        def __get__(self):
            cdef float [:] buffer_
            if self.ptr.type != lib.SUBTITLE_BITMAP:
                return ()
            else:
                return tuple(
                    PyBuffer_FromMemory(self.ptr.pict.data[i], self.width * self.height)
                    if width else None
                    for i, width in enumerate(self.pict_line_sizes)
                )
    

cdef class VideoFrame(object):

    """A frame of video."""

    def __init__(self, Packet packet):
        self.packet = packet
        
    def __dealloc__(self):
        # These are all NULL safe.
        lib.av_free(self.raw_ptr)
        lib.av_free(self.rgb_ptr)
        lib.av_free(self.buffer_)
    
    def __repr__(self):
        return '<%s.%s %dx%d at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.width,
            self.height,
            id(self),
        )
    
    property width:
        """Width of the image, in pixels."""
        def __get__(self): return self.packet.stream.codec.ctx.width

    property height:
        """Height of the image, in pixels."""
        def __get__(self): return self.packet.stream.codec.ctx.height
        
    property key_frame:
        def __get__(self):
            return self.raw_ptr.key_frame

    # Legacy buffer support.
    # See: http://docs.python.org/2/c-api/typeobj.html#PyBufferProcs

    def __getsegcount__(self, Py_ssize_t *len_out):
        if len_out != NULL:
            len_out[0] = <Py_ssize_t> self.packet.stream.buffer_size
        return 1

    def __getreadbuffer__(self, Py_ssize_t index, void **data):
        if index:
            raise RuntimeError("accessing non-existent buffer segment")
        data[0] = <void*> self.rgb_ptr.data[0]
        return <Py_ssize_t> self.packet.stream.buffer_size


cdef class AudioFrame(object):

    """A frame of audio."""

    def __init__(self, Packet packet):
        self.packet = packet
    
    def __dealloc__(self):
        # These are all NULL safe.
        lib.av_free(self.ptr)

