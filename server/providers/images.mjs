import {ProviderError} from './notifications.mjs';
export class ImageStorageProvider{
 status(){return {state:'CONFIGURATION_REQUIRED'}}
 async upload(){throw new ProviderError('IMAGE_STORAGE_CONFIGURATION_REQUIRED')}
 async remove(){throw new ProviderError('IMAGE_STORAGE_CONFIGURATION_REQUIRED')}
 publicUrl(){return null}
}
// A future storage adapter must implement upload/remove and restrict content to
// inspected JPEG/PNG/WebP; an absent image must not block core order processing.
export function imageStorageProvider(){return new ImageStorageProvider()}
