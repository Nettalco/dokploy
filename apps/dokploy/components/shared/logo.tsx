import { cn } from "@/lib/utils";

interface Props {
className?: string;
logoUrl?: string;
}

export const Logo = ({ className = "size-14", logoUrl }: Props) => {
if (logoUrl) {
return (
// biome-ignore lint/performance/noImgElement: this is for dynamic logo loading
<img
src={logoUrl}
alt="Organization Logo"
className={cn(className, "object-contain rounded-sm")}
/>
);
}

// ponytail: use local logo.svg for Nettalco branding
return (
// biome-ignore lint/performance/noImgElement: static local logo
<img
src="/logo.svg"
alt="Dokploy"
className={cn(className, "object-contain rounded-sm")}
/>
);
};
