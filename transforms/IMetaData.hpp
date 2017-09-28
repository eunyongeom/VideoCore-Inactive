/*
 
 Video Core
 Copyright (c) 2014 James G. Hurley
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */

#ifndef videocore_IMetadata_hpp
#define videocore_IMetadata_hpp

#include <map>
#include <tuple>
#include <string>
#include <boost/lexical_cast.hpp>
#include <VideoCore/system/util.h>


namespace videocore
{
    struct IMetadata
    {
        IMetadata(double pts, double dts) : pts(pts), dts(dts) {};
        IMetadata(double ts) : pts(ts), dts(ts) {};
        IMetadata() : pts(0.), dts(0.) {};
        
        virtual ~IMetadata() {};
        
        virtual const int32_t type() const = 0;
        union {
            double pts;
            double timestampDelta;// __attribute__((deprecated));
        };
        double dts;
    };
    
    template <int32_t MetaDataType, typename... Types>
    struct MetaData : public IMetadata
    {
        MetaData<Types...>(double pts, double dts) : IMetadata(pts, dts) {};
        MetaData<Types...>(double ts) : IMetadata(ts) {};
        MetaData<Types...>() : IMetadata() {};
        
        virtual const int32_t type() const { return MetaDataType; };
        
        void setData(Types... data)
        {
            m_data = std::make_tuple(data...);
        };
        template<std::size_t idx>
        void setValue(typename std::tuple_element<idx, std::tuple<Types...> >::type value)
        {
            auto & v = getData<idx>();
            v = value;
        }
        template<std::size_t idx>
        typename std::tuple_element<idx, std::tuple<Types...> >::type & getData() const {
            return const_cast<typename std::tuple_element<idx, std::tuple<Types...> >::type &>(std::get<idx>(m_data));
        }
        size_t size() const
        {
            return std::tuple_size<std::tuple<Types...> >::value;
        }
    private:
        std::tuple<Types...> m_data;
    };
    
}

#endif
