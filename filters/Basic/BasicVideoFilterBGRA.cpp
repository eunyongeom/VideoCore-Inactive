#include <videocore/filters/FilterFactory.h>
#include <videocore/filters/Basic/BasicVideoFilterBGRA.h>
#include <videocore/system/GLESUtil.h>

namespace videocore { namespace filters {
 
    bool BasicVideoFilterBGRA::s_registered = BasicVideoFilterBGRA::registerFilter();
    
    bool
    BasicVideoFilterBGRA::registerFilter()
    {
        FilterFactory::_register("com.videocore.filters.bgra", []() { return new BasicVideoFilterBGRA(); });
        return true;
    }
    
    BasicVideoFilterBGRA::BasicVideoFilterBGRA()
    : IVideoFilter(), m_initialized(false), m_bound(false)
    {
        
    }
    BasicVideoFilterBGRA::~BasicVideoFilterBGRA()
    {
        glDeleteProgram(m_program);
    }
    
    const char * const
    BasicVideoFilterBGRA::vertexKernel() const
    {
        
        KERNEL(GL_ES2_3, m_language,
               attribute vec2 aPos;
               attribute vec2 aCoord;
               varying vec2   vCoord;
               uniform mat4   uMat;
               void main(void) {
                gl_Position = uMat * vec4(aPos,0.,1.);
                vCoord = aCoord;
               }
        )
        
        return nullptr;
    }
    
    const char * const
    BasicVideoFilterBGRA::pixelKernel() const
    {
        
         KERNEL(GL_ES2_3, m_language,
               precision mediump float;
               varying vec2      vCoord;
               uniform sampler2D uTex0;
               void main(void) {
                   gl_FragData[0] = texture2D(uTex0, vCoord);
               }
        )
        
        return nullptr;
    }
    void
    BasicVideoFilterBGRA::initialize()
    {
        switch(m_language) {
            case GL_ES2_3:
            case GL_2: {
                setProgram(build_program(vertexKernel(), pixelKernel()));
    
                m_uMatrix = glGetUniformLocation(m_program, "uMat");
                m_attrPos = glGetAttribLocation(m_program, "aPos");
                m_attrTex = glGetAttribLocation(m_program, "aCoord");
                int unitex = glGetUniformLocation(m_program, "uTex0");
                glUniform1i(unitex, 0);

                m_initialized = true;
            }
                break;
            case GL_3:
                break;
        }
    }
    void
    BasicVideoFilterBGRA::bind()
    {
        switch(m_language) {
            case GL_ES2_3:
            case GL_2:
                if(!m_bound) {
                    if(!initialized()) {
                        initialize();
                    }
                    glUseProgram(m_program);
                    glEnableVertexAttribArray(m_attrPos);
                    glEnableVertexAttribArray(m_attrTex);
                    glVertexAttribPointer(m_attrPos, BUFFER_SIZE_POSITION, GL_FLOAT, GL_FALSE, BUFFER_STRIDE, BUFFER_OFFSET_POSITION);
                    glVertexAttribPointer(m_attrTex, BUFFER_SIZE_POSITION, GL_FLOAT, GL_FALSE, BUFFER_STRIDE, BUFFER_OFFSET_TEXTURE);
                }
                glUniformMatrix4fv(m_uMatrix, 1, GL_FALSE, &m_matrix[0][0]);
                break;
            case GL_3:
                break;
        }
    }
    void
    BasicVideoFilterBGRA::unbind()
    {
        m_bound = false;
    }
}
}