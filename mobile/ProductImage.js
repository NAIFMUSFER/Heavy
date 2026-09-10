import React,{useState} from 'react';
import {Image,Text,View} from 'react-native';
import {productImageUrl} from './catalog.mjs';
export default function ProductImage({product,height=140}){
 const uri=productImageUrl(product.image_url),[failed,setFailed]=useState(null);
 return <View style={{height,width:'100%',alignItems:'center',justifyContent:'center',borderRadius:12,overflow:'hidden',backgroundColor:'#edf3e8'}}>
  <Text accessibilityLabel={product.name} style={{fontSize:42}}>{product.emoji||'🥬'}</Text>
  {uri&&failed!==uri&&<Image source={{uri}} accessibilityLabel={product.name} resizeMode="cover" resizeMethod="resize" referrerPolicy="no-referrer" onError={()=>setFailed(uri)} style={{position:'absolute',width:'100%',height:'100%'}}/>}
 </View>;
}
