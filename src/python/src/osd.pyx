# Copyright 2017-2018 The Open SoC Debug Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cimport cosd
from cutil cimport va_list, vasprintf
from libc.stdlib cimport free
from libc.stdint cimport uint16_t
import logging

from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdlib cimport malloc, free

def osd_library_version():
     cdef const cosd.osd_version* vers = cosd.osd_version_get()
     version_info = {}
     version_info['major'] = vers.major
     version_info['minor'] = vers.minor
     version_info['micro'] = vers.micro
     version_info['suffix'] = vers.suffix
     return version_info

cdef void log_cb(cosd.osd_log_ctx *ctx, int priority, const char *file,
                 int line, const char *fn, const char *format,
                 va_list args):

    # Get log message as unicode string
    cdef char* c_str = NULL
    len = vasprintf(&c_str, format, args)
    if len == -1:
        raise MemoryError()
    try:
        u_msg = c_str[:len].decode('UTF-8')
    finally:
        free(c_str)

    u_file = file.decode('UTF-8')
    u_fn = fn.decode('UTF-8')

    # create log record and pass it to the Python logger
    logger = logging.getLogger(__name__)
    record = logging.LogRecord(name = __name__,
                               level = loglevel_syslog2py(priority),
                               pathname = u_file,
                               lineno = line,
                               func = u_fn,
                               msg = u_msg,
                               args = '',
                               exc_info = None)

    logger.handle(record)

cdef loglevel_py2syslog(py_level):
    """
    Convert Python logging severity levels to syslog levels as defined in
    syslog.h
    """
    if py_level == logging.CRITICAL:
        return 2 # LOG_CRIT
    elif py_level == logging.ERROR:
        return 3 # LOG_ERR
    elif py_level == logging.WARNING:
        return 4 # LOG_WARNING
    elif py_level == logging.INFO:
        return 6 # LOG_INFO
    elif py_level == logging.DEBUG:
        return 7 # LOG_DEBUG
    elif py_level == logging.NOTSET:
        return 0 # LOG_EMERG
    else:
        raise Exception("Unknown loglevel " + str(py_level))


cdef loglevel_syslog2py(syslog_level):
    """
    Convert syslog log severity levels, as defined in syslog.h, to Python ones
    """
    if syslog_level <= 2: # LOG_EMERG, LOG_ALERT, LOG_CRIT
        return logging.CRITICAL
    elif syslog_level == 3: # LOG_ERR
        return logging.ERROR
    elif syslog_level == 4: # LOG_WARNING
        return logging.WARNING
    elif syslog_level <= 6: # LOG_NOTICE, LOG_INFO
        return logging.INFO
    elif syslog_level == 7: # LOG_DEBUG
        return logging.DEBUG
    else:
        raise Exception("Unknown loglevel " + str(syslog_level))


class OsdErrorException(Exception):
    pass

cdef check_osd_result(rv):
    if rv != 0:
        raise OsdErrorException(rv)


cdef class Log:
    cdef cosd.osd_log_ctx* _cself

    def __cinit__(self):
        logger = logging.getLogger(__name__)
        py_loglevel = logger.getEffectiveLevel()
        syslog_loglevel = loglevel_py2syslog(py_loglevel)

        cosd.osd_log_new(&self._cself, syslog_loglevel, log_cb)
        if self._cself is NULL:
            raise MemoryError()

    def __dealloc(self):
        if self._cself is not NULL:
            cosd.osd_log_free(&self._cself)


cdef class Packet:
    cdef cosd.osd_packet* _cself

    def __cinit__(self):
        # XXX: don't make the length fixed! Might require API changes on C side
        cosd.osd_packet_new(&self._cself, 10)
        if self._cself is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._cself is not NULL:
            cosd.osd_packet_free(&self._cself)

    @property
    def src(self):
        return cosd.osd_packet_get_src(self._cself)

    @property
    def dest(self):
        return cosd.osd_packet_get_dest(self._cself)

    @property
    def type(self):
        return cosd.osd_packet_get_type(self._cself)

    @property
    def type_sub(self):
        return cosd.osd_packet_get_type_sub(self._cself)

    def set_header(self, dest, src, type, type_sub):
        cosd.osd_packet_set_header(self._cself, dest, src, type, type_sub)

    def __str__(self):
        cdef char* c_str = NULL
        cosd.osd_packet_to_string(self._cself, &c_str)

        try:
            py_u_str = c_str.decode('UTF-8')
        finally:
            free(c_str)

        return py_u_str


cdef class Hostmod:
    cdef cosd.osd_hostmod_ctx* _cself

    def __cinit__(self, Log log, host_controller_address):
        py_byte_string = host_controller_address.encode('UTF-8')
        cdef char* c_host_controller_address = py_byte_string
        cosd.osd_hostmod_new(&self._cself, log._cself, c_host_controller_address,
                             NULL, NULL)
        # XXX: extend to pass event callback
        if self._cself is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._cself is NULL:
            return

        if self.is_connected():
            self.disconnect()

        cosd.osd_hostmod_free(&self._cself)

    def connect(self):
        cosd.osd_hostmod_connect(self._cself)

    def disconnect(self):
        cosd.osd_hostmod_disconnect(self._cself)

    def is_connected(self):
        return cosd.osd_hostmod_is_connected(self._cself)

    def reg_read(self, diaddr, reg_addr, reg_size_bit = 16, flags = 0):
        cdef uint16_t outvalue
        if reg_size_bit != 16:
            raise Exception("XXX: Extend to support other sizes than 16 bit registers")

        rv = cosd.osd_hostmod_reg_read(self._cself, &outvalue, diaddr, reg_addr,
                                       reg_size_bit, flags)
        if rv != 0:
            raise Exception("Register read failed (%d)" % rv)

        return outvalue

    def reg_write(self, data, diaddr, reg_addr, reg_size_bit = 16, flags = 0):
        if reg_size_bit != 16:
            raise Exception("XXX: Extend to support other sizes than 16 bit registers")

        cdef uint16_t c_data = data

        rv = cosd.osd_hostmod_reg_write(self._cself, &c_data, diaddr, reg_addr,
                                        reg_size_bit, flags)
        if rv != 0:
            raise Exception("Register read failed (%d)" % rv)


cdef class GatewayGlip:
    cdef cosd.osd_gateway_glip_ctx* _cself

    def __cinit__(self, Log log, host_controller_address, device_subnet_addr,
                  glip_backend_name, glip_backend_options):

        b_host_controller_address = host_controller_address.encode('UTF-8')
        cdef char* c_host_controller_address = b_host_controller_address

        b_glip_backend_name = glip_backend_name.encode('UTF-8')
        cdef char* c_glip_backend_name = b_glip_backend_name

        c_glip_backend_options_len = len(glip_backend_options)
        cdef cosd.glip_option* c_glip_backend_options = \
            <cosd.glip_option *>PyMem_Malloc(sizeof(cosd.glip_option) * \
                                             c_glip_backend_options_len)

        try:
            index = 0
            for name, value in glip_backend_options.items():
                b_name = name.encode('UTF-8')
                b_value = value.encode('UTF-8')
                c_glip_backend_options[index].name = b_name
                c_glip_backend_options[index].value = b_value
                index += 1

            cosd.osd_gateway_glip_new(&self._cself, log._cself,
                                      c_host_controller_address,
                                      device_subnet_addr,
                                      c_glip_backend_name,
                                      c_glip_backend_options,
                                      c_glip_backend_options_len)

            if self._cself is NULL:
                raise MemoryError()
        finally:
            PyMem_Free(c_glip_backend_options)

    def __dealloc__(self):
        if self._cself is NULL:
            return

        if self.is_connected():
            self.disconnect()

        cosd.osd_gateway_glip_free(&self._cself)

    def connect(self):
        return cosd.osd_gateway_glip_connect(self._cself)

    def disconnect(self):
        return cosd.osd_gateway_glip_disconnect(self._cself)

    def is_connected(self):
        return cosd.osd_gateway_glip_is_connected(self._cself)


cdef class Hostctrl:
    cdef cosd.osd_hostctrl_ctx* _cself

    def __cinit__(self, Log log, router_address):
        py_byte_string = router_address.encode('UTF-8')
        cdef char* c_router_address = py_byte_string
        cosd.osd_hostctrl_new(&self._cself, log._cself, c_router_address)
        if self._cself is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._cself is NULL:
            return

        if self.is_running():
            self.stop()

        cosd.osd_hostctrl_free(&self._cself)

    def start(self):
        return cosd.osd_hostctrl_start(self._cself)

    def stop(self):
        return cosd.osd_hostctrl_stop(self._cself)

    def is_running(self):
        return cosd.osd_hostctrl_is_running(self._cself)


cdef class Module:
    @staticmethod
    def get_type_short_name(vendor_id, type_id):
        return str(cosd.osd_module_get_type_short_name(vendor_id, type_id))

    @staticmethod
    def get_type_long_name(vendor_id, type_id):
         return str(cosd.osd_module_get_type_long_name(vendor_id, type_id))


cdef class MemoryDescriptor:
    cdef cosd.osd_mem_desc _cself

    def __cinit__(self):
        self._cself.num_regions = 0

    @property
    def regions(self):
        r = []
        for i in range(self._cself.num_regions):
            r.append(self._cself.regions[i])
        return r

    @property
    def addr_width_bit(self):
        return self._cself.addr_width_bit

    @property
    def data_width_bit(self):
        return self._cself.data_width_bit

    @property
    def di_addr(self):
        return self._cself.di_addr

    def __str__(self):
        def sizeof_fmt(num, suffix='B'):
            for unit in ['','Ki','Mi','Gi','Ti','Pi','Ei','Zi']:
                if abs(num) < 1024.0:
                    return "%3.1f %s%s" % (num, unit, suffix)
                num /= 1024.0
            return "%.1f %s%s" % (num, 'Yi', suffix)

        str = "Memory connected to MAM module at DI address %d.\n" %\
            self.di_addr
        str += "address width = %d bit, data width = %d bit\n" %\
            (self.addr_width_bit, self.data_width_bit)
        regions = self.regions
        str += "%d region(s):\n" % len(self.regions)

        r_idx = 0
        for r in self.regions:
            str += "  %d: base address: 0x%x, size: %s\n" %\
                (r_idx, r['baseaddr'], sizeof_fmt(r['memsize']))
            r_idx += 1

        return str

def cl_mam_get_mem_desc(Hostmod hostmod, mam_di_addr):
    mem_desc = MemoryDescriptor()

    cosd.osd_cl_mam_get_mem_desc(hostmod._cself, mam_di_addr, &mem_desc._cself)

    return mem_desc

def cl_mam_write(MemoryDescriptor mem_desc, Hostmod hostmod, data, addr):
    cdef char* c_data = data
    rv = cosd.osd_cl_mam_write(&mem_desc._cself, hostmod._cself, c_data,
                               len(data), addr)
    if rv != 0:
        raise Exception("Memory write failed (%d)" % rv)

def cl_mam_read(MemoryDescriptor mem_desc, Hostmod hostmod, addr, nbyte):
    data = bytearray(nbyte)
    cdef char* c_data = data

    rv = cosd.osd_cl_mam_read(&mem_desc._cself, hostmod._cself, c_data,
                              nbyte, addr)
    if rv != 0:
        raise Exception("Memory read failed (%d)" % rv)

    return data

cdef class MemoryAccess:
    cdef cosd.osd_memaccess_ctx* _cself

    def __cinit__(self, Log log, host_controller_address):
        py_byte_string = host_controller_address.encode('UTF-8')
        cdef char* c_host_controller_address = py_byte_string
        rv = cosd.osd_memaccess_new(&self._cself, log._cself,
                                    c_host_controller_address)
        check_osd_result(rv)
        if self._cself is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._cself is NULL:
            return

        if self.is_connected():
            self.disconnect()

        cosd.osd_memaccess_free(&self._cself)

    def connect(self):
        rv = cosd.osd_memaccess_connect(self._cself)
        check_osd_result(rv)

    def disconnect(self):
        rv = cosd.osd_memaccess_disconnect(self._cself)
        check_osd_result(rv)

    def is_connected(self):
        return cosd.osd_memaccess_is_connected(self._cself)

    def cpus_stop(self, subnet_addr):
        rv = cosd.osd_memaccess_cpus_stop(self._cself, subnet_addr)
        check_osd_result(rv)

    def cpus_start(self, subnet_addr):
        rv = cosd.osd_memaccess_cpus_start(self._cself, subnet_addr)
        check_osd_result(rv)

    def find_memories(self, subnet_addr):
        cdef cosd.osd_mem_desc *memories
        cdef size_t num_memories = 0
        try:
            rv = cosd.osd_memaccess_find_memories(self._cself, subnet_addr,
                                                  &memories,
                                                  &num_memories)
            check_osd_result(rv)

            result_list = []
            for m in range(num_memories):
                mem_desc = MemoryDescriptor()
                mem_desc._cself = memories[m]
                result_list.append(mem_desc)
        finally:
            free(memories)

        return result_list

    def loadelf(self, MemoryDescriptor mem_desc, elf_file_path, verify):
        py_byte_string = elf_file_path.encode('UTF-8')
        cdef char* c_elf_file_path = py_byte_string
        rv = cosd.osd_memaccess_loadelf(self._cself, &mem_desc._cself, c_elf_file_path,
                                        verify)
        check_osd_result(rv)